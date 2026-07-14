using ClipboardSync.WindowsInput;
using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Threading;

namespace ClipboardSyncWin;

internal enum WindowsInputServiceState
{
    Connecting,
    Ready,
    Unavailable,
    Faulted,
    Stopped
}

internal sealed class WindowsInputServiceClient : IDisposable
{
    private const int QueueCapacity = 4096;
    private static readonly TimeSpan ReconnectDelay = TimeSpan.FromSeconds(1);
    private static readonly TimeSpan HeartbeatInterval = TimeSpan.FromSeconds(1);
    private static readonly TimeSpan ResponseTimeout = TimeSpan.FromSeconds(2);

    private readonly int sessionId = Process.GetCurrentProcess().SessionId;
    private readonly BlockingCollection<SecureInputFrame> commands =
        new(new ConcurrentQueue<SecureInputFrame>(), QueueCapacity);
    private readonly ManualResetEventSlim stopping = new(false);
    private readonly Thread worker;
    private readonly object stateLock = new();
    private WindowsInputServiceState state = WindowsInputServiceState.Connecting;
    private string stateDetail = "starting";
    private int queueOverflowed;
    private bool disposed;

    internal event Action? StateChanged;

    internal WindowsInputServiceState State
    {
        get
        {
            lock (stateLock)
            {
                return state;
            }
        }
    }

    internal string StateDetail
    {
        get
        {
            lock (stateLock)
            {
                return stateDetail;
            }
        }
    }

    internal bool IsReady => State == WindowsInputServiceState.Ready;

    internal WindowsInputServiceClient()
    {
        worker = new Thread(WorkerLoop)
        {
            IsBackground = true,
            Name = "WindowsSecureInputClient"
        };
        worker.Start();
    }

    internal bool TryInjectMouse(uint flags, int data, int dx = 0, int dy = 0)
    {
        return TryQueue(new SecureInputFrame(
            SecureInputMessageType.Mouse,
            unchecked((int)flags),
            data,
            dx,
            dy));
    }

    internal bool TryInjectKeyboard(ushort virtualKey, bool keyUp, bool extendedKey)
    {
        return TryQueue(new SecureInputFrame(
            SecureInputMessageType.Keyboard,
            virtualKey,
            keyUp ? 1 : 0,
            extendedKey ? 1 : 0));
    }

    private bool TryQueue(SecureInputFrame frame)
    {
        if (!IsReady)
        {
            return false;
        }
        if (commands.TryAdd(frame))
        {
            return true;
        }

        Interlocked.Exchange(ref queueOverflowed, 1);
        SetState(WindowsInputServiceState.Faulted, $"input queue exceeded {QueueCapacity} events");
        return false;
    }

    private void WorkerLoop()
    {
        InputClientLog.Write($"secure input client starting; session={sessionId}, pid={Environment.ProcessId}");
        while (!stopping.IsSet)
        {
            SetState(WindowsInputServiceState.Connecting, "connecting to the Windows input service");
            try
            {
                using var pipe = new NamedPipeClientStream(
                    ".",
                    SecureInputProtocol.PipeName(sessionId),
                    PipeDirection.InOut,
                    PipeOptions.Asynchronous | PipeOptions.WriteThrough);
                pipe.Connect((int)ReconnectDelay.TotalMilliseconds);
                CompleteHandshake(pipe);
                ClearQueuedCommands();
                Interlocked.Exchange(ref queueOverflowed, 0);
                SetState(WindowsInputServiceState.Ready, "connected");
                RunConnected(pipe);
                if (!stopping.IsSet)
                {
                    throw new IOException("The Windows input service closed its pipe.");
                }
            }
            catch (TimeoutException ex) when (!stopping.IsSet)
            {
                SetState(WindowsInputServiceState.Unavailable, ex.Message);
            }
            catch (IOException ex) when (!stopping.IsSet)
            {
                SetState(WindowsInputServiceState.Unavailable, ex.Message);
            }
            catch (UnauthorizedAccessException ex) when (!stopping.IsSet)
            {
                SetState(WindowsInputServiceState.Faulted, ex.Message);
            }
            catch (InvalidDataException ex) when (!stopping.IsSet)
            {
                SetState(WindowsInputServiceState.Faulted, ex.Message);
            }
            catch (InvalidOperationException ex) when (!stopping.IsSet)
            {
                SetState(WindowsInputServiceState.Faulted, ex.Message);
            }
            finally
            {
                ClearQueuedCommands();
            }

            stopping.Wait(ReconnectDelay);
        }

        SetState(WindowsInputServiceState.Stopped, "stopped");
        InputClientLog.Write("secure input client stopped");
    }

    private void CompleteHandshake(NamedPipeClientStream pipe)
    {
        SecureInputProtocol.WriteFrame(
            pipe,
            new SecureInputFrame(SecureInputMessageType.ClientHello, Environment.ProcessId, sessionId));
        var response = ReadFrameWithTimeout(pipe, ResponseTimeout);
        if (response.Type != SecureInputMessageType.AgentReady || response.B != sessionId)
        {
            throw new InvalidDataException(
                $"Windows input service returned invalid handshake type={response.Type}, session={response.B}.");
        }
    }

    private void RunConnected(NamedPipeClientStream pipe)
    {
        var lastHeartbeat = DateTimeOffset.UtcNow;
        while (!stopping.IsSet && pipe.IsConnected)
        {
            if (Interlocked.CompareExchange(ref queueOverflowed, 0, 0) != 0)
            {
                throw new InvalidOperationException($"Secure input queue exceeded {QueueCapacity} events.");
            }

            if (commands.TryTake(out var frame, 100))
            {
                SecureInputProtocol.WriteFrame(pipe, frame);
            }

            var now = DateTimeOffset.UtcNow;
            if (now - lastHeartbeat < HeartbeatInterval)
            {
                continue;
            }

            SecureInputProtocol.WriteFrame(pipe, new SecureInputFrame(SecureInputMessageType.Ping));
            var response = ReadFrameWithTimeout(pipe, ResponseTimeout);
            if (response.Type != SecureInputMessageType.Pong)
            {
                throw new InvalidDataException($"Windows input service returned {response.Type} instead of Pong.");
            }
            lastHeartbeat = now;
        }
    }

    private static SecureInputFrame ReadFrameWithTimeout(NamedPipeClientStream pipe, TimeSpan timeout)
    {
        var bytes = new byte[SecureInputFrame.Size];
        using var cts = new CancellationTokenSource(timeout);
        try
        {
            pipe.ReadExactlyAsync(bytes, cts.Token).AsTask().GetAwaiter().GetResult();
        }
        catch (OperationCanceledException ex)
        {
            throw new TimeoutException("Timed out waiting for the Windows input service.", ex);
        }
        catch (EndOfStreamException ex)
        {
            throw new IOException("The Windows input service disconnected during a response.", ex);
        }
        return SecureInputFrame.Decode(bytes);
    }

    private void ClearQueuedCommands()
    {
        while (commands.TryTake(out _))
        {
        }
    }

    private void SetState(WindowsInputServiceState nextState, string detail)
    {
        lock (stateLock)
        {
            if (state == nextState && string.Equals(stateDetail, detail, StringComparison.Ordinal))
            {
                return;
            }
            state = nextState;
            stateDetail = detail;
        }

        InputClientLog.Write($"state={nextState}; detail={detail}");
        StateChanged?.Invoke();
    }

    public void Dispose()
    {
        if (disposed)
        {
            return;
        }
        disposed = true;
        stopping.Set();
        commands.CompleteAdding();
        if (!worker.Join(TimeSpan.FromSeconds(4)))
        {
            throw new InvalidOperationException("Windows secure input client did not stop within four seconds.");
        }
        commands.Dispose();
        stopping.Dispose();
    }
}

internal static class InputClientLog
{
    private static readonly object Gate = new();
    private static readonly string LogPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Clipboard Sync",
        "input-client.log");

    internal static void Write(string message)
    {
        var line = $"{DateTimeOffset.Now:O} [{Environment.ProcessId}] {message}{Environment.NewLine}";
        lock (Gate)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(LogPath)!);
            File.AppendAllText(LogPath, line);
        }
        Trace.Write(line);
    }
}
