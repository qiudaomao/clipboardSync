using ClipboardSync.WindowsInput;
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Threading;

namespace ClipboardSyncInputService;

internal sealed record InputAgentOptions(uint SessionId, string UserSid, string StopEventName)
{
    internal static InputAgentOptions Parse(ReadOnlySpan<string> arguments)
    {
        uint? sessionId = null;
        string? userSid = null;
        string? stopEventName = null;
        foreach (var argument in arguments)
        {
            if (argument.StartsWith("--session=", StringComparison.Ordinal))
            {
                if (!uint.TryParse(argument.AsSpan("--session=".Length), out var parsed))
                {
                    throw new ArgumentException($"Invalid input agent session argument: {argument}");
                }
                sessionId = parsed;
            }
            else if (argument.StartsWith("--user-sid=", StringComparison.Ordinal))
            {
                userSid = argument["--user-sid=".Length..];
            }
            else if (argument.StartsWith("--stop-event=", StringComparison.Ordinal))
            {
                stopEventName = argument["--stop-event=".Length..];
            }
            else
            {
                throw new ArgumentException($"Unknown input agent argument: {argument}");
            }
        }

        if (sessionId is null || string.IsNullOrWhiteSpace(userSid) || string.IsNullOrWhiteSpace(stopEventName))
        {
            throw new ArgumentException("Input agent requires --session, --user-sid, and --stop-event.");
        }
        _ = new SecurityIdentifier(userSid);
        return new InputAgentOptions(sessionId.Value, userSid, stopEventName);
    }
}

internal static class InputAgent
{
    internal static int Run(InputAgentOptions options)
    {
        try
        {
            using var identity = WindowsIdentity.GetCurrent();
            if (!identity.IsSystem)
            {
                throw new InvalidOperationException(
                    $"Input agent must run as LocalSystem; current identity is {identity.Name}.");
            }
            if ((uint)Process.GetCurrentProcess().SessionId != options.SessionId)
            {
                throw new InvalidOperationException(
                    $"Input agent is in session {Process.GetCurrentProcess().SessionId}; expected {options.SessionId}.");
            }

            var expectedClientPath = Path.GetFullPath(
                Path.Combine(AppContext.BaseDirectory, "..", "ClipboardSync.exe"));
            var programFiles = Path.GetFullPath(
                Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles));
            if (!expectedClientPath.StartsWith(
                    programFiles.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar,
                    StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidOperationException(
                    $"Trusted Clipboard Sync client path is outside Program Files: {expectedClientPath}");
            }
            if (!File.Exists(expectedClientPath))
            {
                throw new FileNotFoundException("Trusted Clipboard Sync client executable is missing.", expectedClientPath);
            }

            using var stopEvent = EventWaitHandle.OpenExisting(options.StopEventName);
            ServiceLog.Write(
                $"input agent starting; session={options.SessionId}, userSid={options.UserSid}, " +
                $"trustedClient={expectedClientPath}");
            var server = new InputAgentServer(options, expectedClientPath, stopEvent);
            server.Run();
            ServiceLog.Write("input agent stopped cleanly");
            return 0;
        }
        catch (Exception ex)
        {
            ServiceLog.Write($"fatal input agent error: {ex}");
            return 1;
        }
    }
}

internal sealed class InputAgentServer
{
    private readonly InputAgentOptions options;
    private readonly string expectedClientPath;
    private readonly EventWaitHandle stopEvent;
    private readonly PipeSecurity pipeSecurity;
    private readonly WindowsInputInjector injector = new();
    private readonly object pipeGate = new();
    private NamedPipeServerStream? currentPipe;
    private volatile bool stopping;

    internal InputAgentServer(
        InputAgentOptions options,
        string expectedClientPath,
        EventWaitHandle stopEvent)
    {
        this.options = options;
        this.expectedClientPath = expectedClientPath;
        this.stopEvent = stopEvent;
        pipeSecurity = CreatePipeSecurity(options.UserSid);
    }

    internal void Run()
    {
        var stopMonitor = new Thread(WaitForStop)
        {
            IsBackground = true,
            Name = "InputAgentStopMonitor"
        };
        stopMonitor.Start();

        try
        {
            RunLoop();
        }
        finally
        {
            injector.Dispose();
        }
    }

    private void RunLoop()
    {
        while (!stopping)
        {
            using var pipe = CreatePipe();
            SetCurrentPipe(pipe);
            try
            {
                pipe.WaitForConnection();
                if (stopping)
                {
                    break;
                }

                var client = ValidateClient(pipe);
                ServiceLog.Write(
                    $"trusted input client connected; pid={client.ProcessId}, session={client.SessionId}, " +
                    $"path={client.ExecutablePath}");
                ProcessConnection(pipe, client);
            }
            catch (ObjectDisposedException) when (stopping)
            {
                break;
            }
            catch (IOException ex) when (!stopping)
            {
                ServiceLog.Write($"input client pipe disconnected: {ex.Message}");
            }
            catch (InvalidDataException ex) when (!stopping)
            {
                ServiceLog.Write($"input client protocol rejected: {ex.Message}");
            }
            catch (UnauthorizedAccessException ex) when (!stopping)
            {
                ServiceLog.Write($"input client rejected: {ex.Message}");
            }
            finally
            {
                SetCurrentPipe(null);
                injector.ReleaseAll();
            }
        }
    }

    private NamedPipeServerStream CreatePipe()
    {
        return NamedPipeServerStreamAcl.Create(
            SecureInputProtocol.PipeName((int)options.SessionId),
            PipeDirection.InOut,
            maxNumberOfServerInstances: 1,
            PipeTransmissionMode.Byte,
            PipeOptions.WriteThrough,
            inBufferSize: 4096,
            outBufferSize: 4096,
            pipeSecurity,
            HandleInheritability.None,
            additionalAccessRights: 0);
    }

    private void WaitForStop()
    {
        stopEvent.WaitOne();
        stopping = true;
        lock (pipeGate)
        {
            currentPipe?.Dispose();
        }
    }

    private void SetCurrentPipe(NamedPipeServerStream? pipe)
    {
        lock (pipeGate)
        {
            currentPipe = pipe;
            if (stopping)
            {
                currentPipe?.Dispose();
            }
        }
    }

    private TrustedClient ValidateClient(NamedPipeServerStream pipe)
    {
        if (!NativeMethods.GetNamedPipeClientProcessId(
                pipe.SafePipeHandle.DangerousGetHandle(),
                out var processId))
        {
            throw new UnauthorizedAccessException(
                $"GetNamedPipeClientProcessId failed; win32={Marshal.GetLastWin32Error()}.");
        }
        if (!NativeMethods.ProcessIdToSessionId(processId, out var sessionId))
        {
            throw new UnauthorizedAccessException(
                $"ProcessIdToSessionId({processId}) failed; win32={Marshal.GetLastWin32Error()}.");
        }
        if (sessionId != options.SessionId)
        {
            throw new UnauthorizedAccessException(
                $"Client pid {processId} is in session {sessionId}; expected {options.SessionId}.");
        }

        var executablePath = QueryProcessPath(processId);
        if (!string.Equals(executablePath, expectedClientPath, StringComparison.OrdinalIgnoreCase))
        {
            throw new UnauthorizedAccessException(
                $"Client pid {processId} executable is not trusted: {executablePath}");
        }
        var userSid = QueryProcessUserSid(processId);
        if (!string.Equals(userSid, options.UserSid, StringComparison.Ordinal))
        {
            throw new UnauthorizedAccessException(
                $"Client pid {processId} user SID is {userSid}; expected {options.UserSid}.");
        }
        return new TrustedClient(processId, sessionId, executablePath);
    }

    private void ProcessConnection(NamedPipeServerStream pipe, TrustedClient client)
    {
        if (!SecureInputProtocol.TryReadFrame(pipe, out var hello))
        {
            throw new InvalidDataException("Client disconnected before its handshake.");
        }
        if (hello.Type != SecureInputMessageType.ClientHello ||
            hello.A != client.ProcessId ||
            hello.B != client.SessionId)
        {
            throw new InvalidDataException(
                $"Invalid client handshake type={hello.Type}, pid={hello.A}, session={hello.B}.");
        }

        SecureInputProtocol.WriteFrame(
            pipe,
            new SecureInputFrame(
                SecureInputMessageType.AgentReady,
                Environment.ProcessId,
                (int)options.SessionId));

        long mouseCount = 0;
        long keyboardCount = 0;
        while (!stopping && SecureInputProtocol.TryReadFrame(pipe, out var frame))
        {
            switch (frame.Type)
            {
                case SecureInputMessageType.Mouse:
                    injector.InjectMouse(unchecked((uint)frame.A), frame.B, frame.C, frame.D);
                    mouseCount++;
                    break;
                case SecureInputMessageType.Keyboard:
                    if (frame.A is < 0 or > ushort.MaxValue || frame.B is < 0 or > 1 || frame.C is < 0 or > 1)
                    {
                        throw new InvalidDataException("Keyboard frame has out-of-range fields.");
                    }
                    injector.InjectKeyboard((ushort)frame.A, frame.B != 0, frame.C != 0);
                    keyboardCount++;
                    break;
                case SecureInputMessageType.Ping:
                    SecureInputProtocol.WriteFrame(pipe, new SecureInputFrame(SecureInputMessageType.Pong));
                    break;
                default:
                    throw new InvalidDataException($"Unexpected client message type: {frame.Type}.");
            }
        }
        ServiceLog.Write(
            $"trusted input client disconnected; pid={client.ProcessId}, mouseEvents={mouseCount}, " +
            $"keyboardEvents={keyboardCount}");
    }

    private static PipeSecurity CreatePipeSecurity(string userSid)
    {
        var security = new PipeSecurity();
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        var systemSid = new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null);
        security.SetOwner(systemSid);
        security.AddAccessRule(new PipeAccessRule(
            systemSid,
            PipeAccessRights.FullControl,
            AccessControlType.Allow));
        security.AddAccessRule(new PipeAccessRule(
            new SecurityIdentifier(userSid),
            PipeAccessRights.ReadWrite,
            AccessControlType.Allow));
        return security;
    }

    private static string QueryProcessPath(uint processId)
    {
        using var process = NativeMethods.OpenProcess(
            NativeMethods.ProcessQueryLimitedInformation,
            inheritHandle: false,
            processId);
        if (process.IsInvalid)
        {
            throw new UnauthorizedAccessException(
                $"OpenProcess({processId}) failed; win32={Marshal.GetLastWin32Error()}.");
        }
        var capacity = 32_768;
        var path = new StringBuilder(capacity);
        if (!NativeMethods.QueryFullProcessImageName(process, 0, path, ref capacity))
        {
            throw new UnauthorizedAccessException(
                $"QueryFullProcessImageName({processId}) failed; win32={Marshal.GetLastWin32Error()}.");
        }
        return Path.GetFullPath(path.ToString());
    }

    private static string QueryProcessUserSid(uint processId)
    {
        using var process = NativeMethods.OpenProcess(
            NativeMethods.ProcessQueryLimitedInformation,
            inheritHandle: false,
            processId);
        if (process.IsInvalid)
        {
            throw new UnauthorizedAccessException(
                $"OpenProcess({processId}) for token failed; win32={Marshal.GetLastWin32Error()}.");
        }
        if (!NativeMethods.OpenProcessToken(process, NativeMethods.TokenQuery, out var token))
        {
            throw new UnauthorizedAccessException(
                $"OpenProcessToken({processId}) failed; win32={Marshal.GetLastWin32Error()}.");
        }
        using (token)
        using (var identity = new WindowsIdentity(token.DangerousGetHandle()))
        {
            return identity.User?.Value
                ?? throw new UnauthorizedAccessException($"Client pid {processId} token has no user SID.");
        }
    }

    private sealed record TrustedClient(int ProcessId, int SessionId, string ExecutablePath)
    {
        internal TrustedClient(uint processId, uint sessionId, string executablePath)
            : this(checked((int)processId), checked((int)sessionId), executablePath)
        {
        }
    }
}
