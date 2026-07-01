using System;
using System.Buffers.Binary;
using System.Collections.Concurrent;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace ClipboardSyncWin;

internal interface ISyncTransport : IDisposable
{
    event Action<string>? StatusChanged;
    event Action<string>? MessageReceived;
    event Action<int>? PeerCountChanged;

    void Start();
    void Stop();
    Task SendAsync(string message);
}

internal sealed class ClientTransport : ISyncTransport
{
    private static readonly TimeSpan KeepAliveInterval = TimeSpan.FromSeconds(10);
    private static readonly TimeSpan KeepAliveTimeout = TimeSpan.FromSeconds(5);
    private readonly string host;
    private readonly int port;
    private readonly SemaphoreSlim sendLock = new(1, 1);
    private CancellationTokenSource? cts;
    private ClientWebSocket? socket;

    public event Action<string>? StatusChanged;
    public event Action<string>? MessageReceived;
    public event Action<int>? PeerCountChanged;

    public ClientTransport(string host, int port)
    {
        this.host = host;
        this.port = port;
    }

    public void Start()
    {
        cts?.Cancel();
        cts = new CancellationTokenSource();
        _ = RunAsync(cts.Token);
    }

    public void Stop()
    {
        cts?.Cancel();
        socket?.Abort();
        socket?.Dispose();
        socket = null;
        PeerCountChanged?.Invoke(0);
        StatusChanged?.Invoke(AppText.Text("status.stopped"));
    }

    public async Task SendAsync(string message)
    {
        var activeSocket = socket;
        if (activeSocket?.State != WebSocketState.Open)
        {
            return;
        }

        var bytes = Encoding.UTF8.GetBytes(message);
        await sendLock.WaitAsync().ConfigureAwait(false);
        try
        {
            await activeSocket.SendAsync(bytes, WebSocketMessageType.Text, true, CancellationToken.None).ConfigureAwait(false);
        }
        catch
        {
            StatusChanged?.Invoke(AppText.Text("status.sendFailed"));
        }
        finally
        {
            sendLock.Release();
        }
    }

    public void Dispose()
    {
        Stop();
        sendLock.Dispose();
        cts?.Dispose();
    }

    private async Task RunAsync(CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            try
            {
                using var ws = new ClientWebSocket();
                ConfigureKeepAlive(ws);
                socket = ws;
                StatusChanged?.Invoke(AppText.Format("status.connecting", host, port));
                await ws.ConnectAsync(new Uri($"ws://{host}:{port}/"), token).ConfigureAwait(false);
                PeerCountChanged?.Invoke(1);
                StatusChanged?.Invoke(AppText.Format("status.connected", host, port));
                await ReceiveLoopAsync(ws, token).ConfigureAwait(false);
                if (!token.IsCancellationRequested)
                {
                    PeerCountChanged?.Invoke(0);
                    StatusChanged?.Invoke(AppText.Text("status.disconnectedRetrying"));
                }
            }
            catch (OperationCanceledException)
            {
                break;
            }
            catch
            {
                if (!token.IsCancellationRequested)
                {
                    PeerCountChanged?.Invoke(0);
                    StatusChanged?.Invoke(AppText.Text("status.disconnectedRetrying"));
                }
            }

            if (!token.IsCancellationRequested)
            {
                try
                {
                    await Task.Delay(TimeSpan.FromSeconds(2), token).ConfigureAwait(false);
                }
                catch (OperationCanceledException)
                {
                    break;
                }
            }
        }
    }

    private static void ConfigureKeepAlive(ClientWebSocket ws)
    {
        ws.Options.KeepAliveInterval = KeepAliveInterval;

        var timeoutProperty = ws.Options.GetType().GetProperty("KeepAliveTimeout");
        if (timeoutProperty?.CanWrite == true)
        {
            timeoutProperty.SetValue(ws.Options, KeepAliveTimeout);
        }
    }

    private async Task ReceiveLoopAsync(ClientWebSocket ws, CancellationToken token)
    {
        var buffer = new byte[8192];
        while (ws.State == WebSocketState.Open && !token.IsCancellationRequested)
        {
            using var message = new MemoryStream();
            WebSocketReceiveResult result;
            do
            {
                result = await ws.ReceiveAsync(buffer, token).ConfigureAwait(false);
                if (result.MessageType == WebSocketMessageType.Close)
                {
                    return;
                }
                message.Write(buffer, 0, result.Count);
                if (message.Length > ClipboardLimits.MaxWebSocketMessageBytes)
                {
                    return;
                }
            } while (!result.EndOfMessage);

            if (result.MessageType == WebSocketMessageType.Text)
            {
                try
                {
                    MessageReceived?.Invoke(Encoding.UTF8.GetString(message.ToArray()));
                }
                catch
                {
                    StatusChanged?.Invoke(AppText.Text("status.messageHandlerFailed"));
                }
            }
        }
    }
}

internal sealed class ServerTransport : ISyncTransport
{
    private readonly int port;
    private readonly ConcurrentDictionary<Guid, ServerPeer> peers = new();
    private CancellationTokenSource? cts;
    private TcpListener? listener;

    public event Action<string>? StatusChanged;
    public event Action<string>? MessageReceived;
    public event Action<int>? PeerCountChanged;

    public ServerTransport(int port)
    {
        this.port = port;
    }

    public void Start()
    {
        try
        {
            cts?.Cancel();
            cts = new CancellationTokenSource();
            listener = new TcpListener(IPAddress.Any, port);
            listener.Start();
            PeerCountChanged?.Invoke(0);
            StatusChanged?.Invoke(AppText.Format("status.serverPeers", NetworkAddress.ServerUrl(port), 0));
            _ = AcceptLoopAsync(cts.Token);
        }
        catch (Exception ex)
        {
            StatusChanged?.Invoke(AppText.Format("status.serverError", ex.Message));
        }
    }

    public void Stop()
    {
        cts?.Cancel();
        listener?.Stop();
        foreach (var peer in peers.Values)
        {
            peer.Close();
        }
        peers.Clear();
        PeerCountChanged?.Invoke(0);
        StatusChanged?.Invoke(AppText.Text("status.stopped"));
    }

    public Task SendAsync(string message)
    {
        return BroadcastAsync(message, null);
    }

    public void Dispose()
    {
        Stop();
        cts?.Dispose();
    }

    private async Task AcceptLoopAsync(CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            try
            {
                var client = await listener!.AcceptTcpClientAsync(token).ConfigureAwait(false);
                var id = Guid.NewGuid();
                var peer = new ServerPeer(client);
                peers[id] = peer;

                peer.TextReceived += async text =>
                {
                    try
                    {
                        MessageReceived?.Invoke(text);
                    }
                    catch
                    {
                        StatusChanged?.Invoke(AppText.Text("status.messageHandlerFailed"));
                    }
                    await BroadcastAsync(text, id).ConfigureAwait(false);
                };
                peer.Ready += PushStatus;
                peer.Closed += () =>
                {
                    peers.TryRemove(id, out _);
                    PushStatus();
                };

                _ = peer.RunAsync(token);
            }
            catch (OperationCanceledException)
            {
                break;
            }
            catch
            {
                StatusChanged?.Invoke(AppText.Text("status.serverAcceptFailed"));
            }
        }
    }

    private async Task BroadcastAsync(string message, Guid? excludedPeer)
    {
        foreach (var item in peers)
        {
            if (excludedPeer.HasValue && item.Key == excludedPeer.Value)
            {
                continue;
            }

            if (!item.Value.IsReady)
            {
                continue;
            }

            try
            {
                await item.Value.SendTextAsync(message).ConfigureAwait(false);
            }
            catch
            {
                item.Value.Close();
            }
        }
    }

    private void PushStatus()
    {
        var readyPeerCount = peers.Count(item => item.Value.IsReady);
        PeerCountChanged?.Invoke(readyPeerCount);
        StatusChanged?.Invoke(AppText.Format("status.serverPeers", NetworkAddress.ServerUrl(port), readyPeerCount));
    }
}

internal sealed class ServerPeer
{
    private readonly TcpClient client;
    private readonly NetworkStream stream;
    private readonly SemaphoreSlim sendLock = new(1, 1);
    private bool closed;

    public bool IsReady { get; private set; }
    public event Action? Ready;
    public event Func<string, Task>? TextReceived;
    public event Action? Closed;

    public ServerPeer(TcpClient client)
    {
        this.client = client;
        stream = client.GetStream();
    }

    public async Task RunAsync(CancellationToken token)
    {
        try
        {
            if (!await HandshakeAsync(token).ConfigureAwait(false))
            {
                return;
            }

            IsReady = true;
            Ready?.Invoke();

            while (!token.IsCancellationRequested)
            {
                var frame = await ReadFrameAsync(token).ConfigureAwait(false);
                if (frame.Closed)
                {
                    return;
                }

                if (frame.Text is not null && TextReceived is not null)
                {
                    await TextReceived.Invoke(frame.Text).ConfigureAwait(false);
                }
            }
        }
        catch
        {
            // Treat malformed frames and broken sockets as disconnects.
        }
        finally
        {
            Close();
        }
    }

    public async Task SendTextAsync(string text)
    {
        if (closed || !IsReady)
        {
            return;
        }

        try
        {
            await SendFrameAsync(0x1, Encoding.UTF8.GetBytes(text), CancellationToken.None).ConfigureAwait(false);
        }
        catch
        {
            Close();
        }
    }

    public void Close()
    {
        if (closed)
        {
            return;
        }

        closed = true;
        client.Close();
        sendLock.Dispose();
        Closed?.Invoke();
    }

    private async Task<bool> HandshakeAsync(CancellationToken token)
    {
        var headerBytes = await ReadHttpHeaderAsync(token).ConfigureAwait(false);
        if (headerBytes is null)
        {
            return false;
        }

        var header = Encoding.UTF8.GetString(headerBytes);
        var key = GetHeaderValue(header, "Sec-WebSocket-Key");
        if (string.IsNullOrWhiteSpace(key))
        {
            return false;
        }

        var response =
            "HTTP/1.1 101 Switching Protocols\r\n" +
            "Upgrade: websocket\r\n" +
            "Connection: Upgrade\r\n" +
            $"Sec-WebSocket-Accept: {AcceptKey(key)}\r\n" +
            "\r\n";

        var responseBytes = Encoding.UTF8.GetBytes(response);
        await stream.WriteAsync(responseBytes, token).ConfigureAwait(false);
        return true;
    }

    private async Task<FrameResult> ReadFrameAsync(CancellationToken token)
    {
        var header = await ReadExactAsync(2, token).ConfigureAwait(false);
        if (header is null)
        {
            return FrameResult.Close;
        }

        var opcode = (byte)(header[0] & 0x0f);
        var masked = (header[1] & 0x80) != 0;
        var length = (ulong)(header[1] & 0x7f);

        if (length == 126)
        {
            var lengthBytes = await ReadExactAsync(2, token).ConfigureAwait(false);
            if (lengthBytes is null)
            {
                return FrameResult.Close;
            }
            length = BinaryPrimitives.ReadUInt16BigEndian(lengthBytes);
        }
        else if (length == 127)
        {
            var lengthBytes = await ReadExactAsync(8, token).ConfigureAwait(false);
            if (lengthBytes is null)
            {
                return FrameResult.Close;
            }
            length = BinaryPrimitives.ReadUInt64BigEndian(lengthBytes);
        }

        if (length > ClipboardLimits.MaxWebSocketMessageBytes)
        {
            return FrameResult.Close;
        }

        byte[]? mask = null;
        if (masked)
        {
            mask = await ReadExactAsync(4, token).ConfigureAwait(false);
            if (mask is null)
            {
                return FrameResult.Close;
            }
        }

        var payload = await ReadExactAsync((int)length, token).ConfigureAwait(false);
        if (payload is null)
        {
            return FrameResult.Close;
        }

        if (mask is not null)
        {
            for (var index = 0; index < payload.Length; index++)
            {
                payload[index] ^= mask[index % 4];
            }
        }

        if (opcode == 0x8)
        {
            return FrameResult.Close;
        }

        if (opcode == 0x9)
        {
            await SendFrameAsync(0xA, payload, token).ConfigureAwait(false);
            return FrameResult.Empty;
        }

        if (opcode == 0x1)
        {
            return new FrameResult(false, Encoding.UTF8.GetString(payload));
        }

        return FrameResult.Empty;
    }

    private async Task SendFrameAsync(byte opcode, byte[] payload, CancellationToken token)
    {
        await sendLock.WaitAsync(token).ConfigureAwait(false);
        try
        {
            using var frame = new MemoryStream();
            frame.WriteByte((byte)(0x80 | opcode));

            if (payload.Length < 126)
            {
                frame.WriteByte((byte)payload.Length);
            }
            else if (payload.Length <= ushort.MaxValue)
            {
                frame.WriteByte(126);
                var lengthBytes = new byte[2];
                BinaryPrimitives.WriteUInt16BigEndian(lengthBytes, (ushort)payload.Length);
                frame.Write(lengthBytes);
            }
            else
            {
                frame.WriteByte(127);
                var lengthBytes = new byte[8];
                BinaryPrimitives.WriteUInt64BigEndian(lengthBytes, (ulong)payload.Length);
                frame.Write(lengthBytes);
            }

            frame.Write(payload);
            await stream.WriteAsync(frame.ToArray(), token).ConfigureAwait(false);
        }
        finally
        {
            sendLock.Release();
        }
    }

    private async Task<byte[]?> ReadHttpHeaderAsync(CancellationToken token)
    {
        using var memory = new MemoryStream();
        var buffer = new byte[1];

        while (memory.Length < 16_384)
        {
            var read = await stream.ReadAsync(buffer, token).ConfigureAwait(false);
            if (read == 0)
            {
                return null;
            }

            memory.WriteByte(buffer[0]);
            var data = memory.GetBuffer();
            var length = (int)memory.Length;
            if (length >= 4 &&
                data[length - 4] == '\r' &&
                data[length - 3] == '\n' &&
                data[length - 2] == '\r' &&
                data[length - 1] == '\n')
            {
                return memory.ToArray();
            }
        }

        return null;
    }

    private async Task<byte[]?> ReadExactAsync(int length, CancellationToken token)
    {
        var buffer = new byte[length];
        var offset = 0;

        while (offset < length)
        {
            var read = await stream.ReadAsync(buffer.AsMemory(offset, length - offset), token).ConfigureAwait(false);
            if (read == 0)
            {
                return null;
            }
            offset += read;
        }

        return buffer;
    }

    private static string? GetHeaderValue(string header, string name)
    {
        foreach (var line in header.Split("\r\n", StringSplitOptions.RemoveEmptyEntries))
        {
            var parts = line.Split(':', 2);
            if (parts.Length == 2 && parts[0].Trim().Equals(name, StringComparison.OrdinalIgnoreCase))
            {
                return parts[1].Trim();
            }
        }

        return null;
    }

    private static string AcceptKey(string key)
    {
        var input = Encoding.ASCII.GetBytes(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
        return Convert.ToBase64String(SHA1.HashData(input));
    }

    private readonly record struct FrameResult(bool Closed, string? Text)
    {
        public static FrameResult Close => new(true, null);
        public static FrameResult Empty => new(false, null);
    }
}
