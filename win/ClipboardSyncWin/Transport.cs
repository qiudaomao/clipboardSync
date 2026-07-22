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

/// Names the WebSocket subprotocol that marks a connection as the dedicated low-latency input
/// channel. Both sides speak the same wire format on either connection; the split only exists so
/// small input frames never queue behind multi-megabyte clipboard/file/tunnel frames on one TCP
/// stream (head-of-line blocking felt as mouse stutter). Negotiated per RFC 6455: a client that
/// wants the channel requests this subprotocol, and only a server that understands it echoes it
/// back — an old peer fails the negotiation and everything transparently rides the one data
/// connection as before.
internal static class TransportChannels
{
    public const string InputSubprotocol = "clipboardsync-input";
}

internal interface ISyncTransport : IDisposable
{
    event Action<string>? StatusChanged;
    /// Delivers a received payload; the flag is true when it arrived on the dedicated input
    /// channel, letting the app process it on a path that never waits on bulk work.
    event Action<string, bool>? MessageReceived;
    /// Delivers a received binary frame. Only port-forward "data" frames use this - see
    /// <see cref="TunnelFrame"/> for why they bypass the JSON envelope. Awaited by the receive
    /// loop, so a handler that blocks on a full tunnel queue stops this connection being drained -
    /// that is the inbound half of the port-forward back-pressure.
    event Func<byte[], Task>? BinaryReceived;
    event Action<int>? PeerCountChanged;

    void Start();
    void Stop();
    /// <c>to</c> is an optional routing hint naming the intended receiver's device id. A server
    /// transport delivers the message to just that peer's connection when it knows which one that
    /// is (falling back to broadcast); a client transport ignores it — its server relays by the
    /// same hint carried inside the message envelope. <c>realtime</c> prefers the dedicated input
    /// channel when one is established, falling back to the data connection when it isn't.
    Task SendAsync(string message, string? to = null, bool realtime = false);

    /// Binary counterpart of <see cref="SendAsync"/>, always on the data connection. Routing works
    /// the same way, except a relay reads the target out of the frame header instead of a JSON
    /// envelope. Only port-forward "data" frames use this - see <see cref="TunnelFrame"/>.
    Task SendBinaryAsync(byte[] frame, string? to = null);
}

internal sealed class ClientTransport : ISyncTransport
{
    private static readonly TimeSpan KeepAliveInterval = TimeSpan.FromSeconds(10);
    private static readonly TimeSpan KeepAliveTimeout = TimeSpan.FromSeconds(5);
    private readonly string host;
    private readonly int port;
    private readonly SemaphoreSlim sendLock = new(1, 1);
    private readonly SemaphoreSlim inputSendLock = new(1, 1);
    private CancellationTokenSource? cts;
    private ClientWebSocket? socket;
    /// Optional second connection dedicated to input frames, so they never queue behind bulk
    /// clipboard/file/tunnel frames on the data connection's TCP stream. Established only when
    /// the server echoes the input subprotocol; an old server fails the negotiation and the
    /// data connection carries everything, exactly as before.
    private ClientWebSocket? inputSocket;

    public event Action<string>? StatusChanged;
    public event Action<string, bool>? MessageReceived;
    public event Func<byte[], Task>? BinaryReceived;
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
        inputSocket?.Abort();
        inputSocket?.Dispose();
        inputSocket = null;
        PeerCountChanged?.Invoke(0);
        StatusChanged?.Invoke(AppText.Text("status.stopped"));
    }

    public async Task SendAsync(string message, string? to = null, bool realtime = false)
    {
        // A client has a single connection per channel to its server; the server relays targeted
        // messages using the routing hint inside the envelope itself.
        var input = inputSocket;
        var useInput = realtime && input?.State == WebSocketState.Open;
        var activeSocket = useInput ? input : socket;
        if (activeSocket?.State != WebSocketState.Open)
        {
            return;
        }

        var bytes = Encoding.UTF8.GetBytes(message);
        var activeLock = useInput ? inputSendLock : sendLock;
        await activeLock.WaitAsync().ConfigureAwait(false);
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
            activeLock.Release();
        }
    }

    public void Dispose()
    {
        Stop();
        sendLock.Dispose();
        inputSendLock.Dispose();
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
                using var inputChannelCts = CancellationTokenSource.CreateLinkedTokenSource(token);
                var inputChannelTask = RunInputChannelAsync(ws, inputChannelCts.Token);
                try
                {
                    await ReceiveLoopAsync(ws, token).ConfigureAwait(false);
                }
                finally
                {
                    inputChannelCts.Cancel();
                    try
                    {
                        await inputChannelTask.ConfigureAwait(false);
                    }
                    catch
                    {
                        // Input channel teardown failures are irrelevant; it's an optimization.
                    }
                }
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

    /// Maintains the auxiliary input-channel connection while the given data connection is open.
    /// If the server doesn't echo the subprotocol it predates the channel split — give up until
    /// the next data connection; transient failures retry, and input rides the data connection
    /// in the meantime.
    private async Task RunInputChannelAsync(ClientWebSocket dataSocket, CancellationToken token)
    {
        while (!token.IsCancellationRequested && dataSocket.State == WebSocketState.Open)
        {
            try
            {
                using var ws = new ClientWebSocket();
                ConfigureKeepAlive(ws);
                ws.Options.AddSubProtocol(TransportChannels.InputSubprotocol);
                await ws.ConnectAsync(new Uri($"ws://{host}:{port}/"), token).ConfigureAwait(false);
                if (ws.SubProtocol != TransportChannels.InputSubprotocol)
                {
                    ws.Abort();
                    return;
                }
                inputSocket = ws;
                try
                {
                    await ReceiveLoopAsync(ws, token, viaInputChannel: true).ConfigureAwait(false);
                }
                finally
                {
                    inputSocket = null;
                }
            }
            catch (OperationCanceledException)
            {
                return;
            }
            catch (WebSocketException)
            {
                // Servers predating the split reject or mishandle the subprotocol request;
                // treat it as unsupported rather than hammering them with retries.
                return;
            }
            catch
            {
                // Transient failure; fall through to the retry delay.
            }

            try
            {
                await Task.Delay(TimeSpan.FromSeconds(5), token).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                return;
            }
        }
    }

    /// Binary frames are bulk traffic, so they always take the data connection - the input channel
    /// exists to keep small realtime frames out from behind exactly this kind of payload.
    public async Task SendBinaryAsync(byte[] frame, string? to = null)
    {
        var activeSocket = socket;
        if (activeSocket?.State != WebSocketState.Open)
        {
            return;
        }

        await sendLock.WaitAsync().ConfigureAwait(false);
        try
        {
            await activeSocket.SendAsync(frame, WebSocketMessageType.Binary, true, CancellationToken.None).ConfigureAwait(false);
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

    private async Task ReceiveLoopAsync(ClientWebSocket ws, CancellationToken token, bool viaInputChannel = false)
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

            try
            {
                if (result.MessageType == WebSocketMessageType.Text)
                {
                    MessageReceived?.Invoke(Encoding.UTF8.GetString(message.ToArray()), viaInputChannel);
                }
                else if (result.MessageType == WebSocketMessageType.Binary)
                {
                    // Port-forward "data" frames arrive here rather than as JSON; see TunnelFrame.
                    // Awaited so a congested tunnel stops this socket being drained.
                    var binaryHandler = BinaryReceived;
                    if (binaryHandler is not null)
                    {
                        await binaryHandler(message.ToArray()).ConfigureAwait(false);
                    }
                }
            }
            catch
            {
                StatusChanged?.Invoke(AppText.Text("status.messageHandlerFailed"));
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

    /// This machine's own device id. Messages routed to it are already delivered locally via
    /// MessageReceived, so the relay must not fall back to broadcasting them at other peers.
    public string? LocalDeviceId { get; set; }

    public event Action<string>? StatusChanged;
    public event Action<string, bool>? MessageReceived;
    public event Func<byte[], Task>? BinaryReceived;
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
            StatusChanged?.Invoke(AppText.Format("status.serverPeers", NetworkAddress.ServerAddress(port), 0));
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

    public Task SendAsync(string message, string? to = null, bool realtime = false)
    {
        return DeliverAsync(message, to, excludedPeer: null, preferInput: realtime);
    }

    public Task SendBinaryAsync(byte[] frame, string? to = null)
    {
        return DeliverBinaryAsync(frame, to, excludedPeer: null);
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
                    // Envelope routing hints are plaintext, so the relay can learn which
                    // connection belongs to which device (From) and deliver targeted traffic (To)
                    // to just that peer instead of broadcasting file chunks and tunnel data to
                    // everyone.
                    var routing = ParseRouting(text);
                    if (!string.IsNullOrEmpty(routing?.From))
                    {
                        peer.DeviceId = routing!.From;
                    }
                    // A message addressed to some other device is pure relay traffic. Handing it
                    // to MessageReceived would run a full AES-GCM decrypt of a ~100 KB tunnel or
                    // file chunk only for the receiver-side target filter to drop it - on a busy
                    // forward that is the relay's single largest cost. Anything unaddressed still
                    // goes through, so broadcasts and older peers that omit the hint are
                    // unaffected.
                    if (!IsRelayOnly(routing?.To))
                    {
                        try
                        {
                            MessageReceived?.Invoke(text, peer.IsInputChannel);
                        }
                        catch
                        {
                            StatusChanged?.Invoke(AppText.Text("status.messageHandlerFailed"));
                        }
                    }
                    // Relay on the same class of channel the message arrived on, so one peer's
                    // input frames reach the next peer's input connection, not its bulk stream.
                    await DeliverAsync(text, routing?.To, id, preferInput: peer.IsInputChannel).ConfigureAwait(false);
                };
                peer.BinaryReceived += async frame =>
                {
                    // A binary frame is a port-forward "data" frame; its target sits in the
                    // plaintext header, so the relay routes it without being able to read the
                    // payload. Same early-out as the text path: a frame for another device is
                    // never handed to the local app.
                    var target = TunnelFrame.PeekTarget(frame);
                    if (!IsRelayOnly(target))
                    {
                        try
                        {
                            var binaryHandler = BinaryReceived;
                            if (binaryHandler is not null)
                            {
                                await binaryHandler(frame).ConfigureAwait(false);
                            }
                        }
                        catch
                        {
                            StatusChanged?.Invoke(AppText.Text("status.messageHandlerFailed"));
                        }
                    }
                    await DeliverBinaryAsync(frame, target, id).ConfigureAwait(false);
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

    private static EnvelopeRouting? ParseRouting(string message)
    {
        try
        {
            return EnvelopeRouting.Scan(message);
        }
        catch
        {
            return null;
        }
    }

    /// True when <c>to</c> names a device that definitely isn't this one, so the frame is only
    /// passing through. Deliberately conservative: an absent hint, an empty hint, or an unknown
    /// local device id all return false, so the frame is still handled locally.
    private bool IsRelayOnly(string? to)
        => !string.IsNullOrEmpty(to) && !string.IsNullOrEmpty(LocalDeviceId) && to != LocalDeviceId;

    /// Sends the message to the one ready peer registered under the <c>to</c> device id, or to
    /// every ready peer (except <c>excludedPeer</c>) when the target is absent or not (yet)
    /// known — a peer that hasn't sent anything since connecting has no registered device id, and
    /// the receiver-side target filter makes the broadcast fallback harmless. Targeted delivery
    /// prefers the device's connection matching the message's channel (input vs data), falling
    /// back to whichever it has; broadcasts go to data connections only, since every device has
    /// exactly one and duplicates on the auxiliary input channel would double-deliver.
    private async Task DeliverAsync(string message, string? to, Guid? excludedPeer, bool preferInput = false)
    {
        if (!string.IsNullOrEmpty(to))
        {
            if (to == LocalDeviceId)
            {
                return;
            }
            var candidates = peers
                .Where(item => item.Value.DeviceId == to && item.Value.IsReady && !(excludedPeer.HasValue && item.Key == excludedPeer.Value))
                .Select(item => item.Value)
                .ToList();
            var target = candidates.FirstOrDefault(peer => peer.IsInputChannel == preferInput) ?? candidates.FirstOrDefault();
            if (target is not null)
            {
                try
                {
                    await target.SendTextAsync(message).ConfigureAwait(false);
                }
                catch
                {
                    target.Close();
                }
                return;
            }
            if (peers.Any(item => item.Value.DeviceId == to && item.Value.IsReady))
            {
                // The only matching connection is the excluded source itself; don't broadcast.
                return;
            }
        }

        await BroadcastAsync(message, excludedPeer).ConfigureAwait(false);
    }

    private async Task BroadcastAsync(string message, Guid? excludedPeer)
    {
        foreach (var item in peers)
        {
            if (excludedPeer.HasValue && item.Key == excludedPeer.Value)
            {
                continue;
            }

            if (!item.Value.IsReady || item.Value.IsInputChannel)
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

    /// Binary counterpart of <see cref="DeliverAsync"/>. Tunnel frames are always addressed, so
    /// there is no input-channel preference to make - they belong on the data connection either way.
    private async Task DeliverBinaryAsync(byte[] frame, string? to, Guid? excludedPeer)
    {
        if (!string.IsNullOrEmpty(to))
        {
            if (to == LocalDeviceId)
            {
                return;
            }
            var target = peers
                .Where(item => item.Value.DeviceId == to && item.Value.IsReady && !item.Value.IsInputChannel
                    && !(excludedPeer.HasValue && item.Key == excludedPeer.Value))
                .Select(item => item.Value)
                .FirstOrDefault();
            if (target is not null)
            {
                try
                {
                    await target.SendBinaryAsync(frame).ConfigureAwait(false);
                }
                catch
                {
                    target.Close();
                }
                return;
            }
            if (peers.Any(item => item.Value.DeviceId == to && item.Value.IsReady))
            {
                // The only matching connection is the excluded source itself; don't broadcast.
                return;
            }
        }

        foreach (var item in peers)
        {
            if (excludedPeer.HasValue && item.Key == excludedPeer.Value)
            {
                continue;
            }
            if (!item.Value.IsReady || item.Value.IsInputChannel)
            {
                continue;
            }
            try
            {
                await item.Value.SendBinaryAsync(frame).ConfigureAwait(false);
            }
            catch
            {
                item.Value.Close();
            }
        }
    }

    private void PushStatus()
    {
        // Input-channel connections are auxiliary; a device's presence is its data connection.
        var readyPeerCount = peers.Count(item => item.Value.IsReady && !item.Value.IsInputChannel);
        PeerCountChanged?.Invoke(readyPeerCount);
        StatusChanged?.Invoke(AppText.Format("status.serverPeers", NetworkAddress.ServerAddress(port), readyPeerCount));
    }
}

internal sealed class ServerPeer
{
    private readonly TcpClient client;
    private readonly NetworkStream stream;
    private readonly SemaphoreSlim sendLock = new(1, 1);
    private bool closed;
    // Reassembly state for a fragmented message (RFC 6455 §5.4): the first frame's opcode and the
    // fragment payloads accumulated so far. Clients are allowed to split any message into
    // continuation frames — Apple's WebSocket client does for large messages.
    private byte? fragmentOpcode;
    private MemoryStream? fragmentBuffer;

    public bool IsReady { get; private set; }
    /// True when the client negotiated the dedicated input subprotocol during the handshake.
    public bool IsInputChannel { get; private set; }
    /// The device id this connection last announced via an envelope's From hint, once known.
    public string? DeviceId { get; set; }
    public event Action? Ready;
    public event Func<string, Task>? TextReceived;
    public event Func<byte[], Task>? BinaryReceived;
    public event Action? Closed;

    public ServerPeer(TcpClient client)
    {
        this.client = client;
        // Nagle would hold a small frame back waiting for more bytes while the peer's delayed ACK
        // waits for a response - worth ~40 ms on every interactive round trip through a tunnel or
        // an input event. Frames are already batched by the sender, so kernel coalescing buys
        // nothing. (ClientWebSocket's own sockets already run with NoDelay via SocketsHttpHandler.)
        try
        {
            client.NoDelay = true;
        }
        catch (SocketException)
        {
            // A socket that died between accept and here; the read loop reports it.
        }
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
                else if (frame.Binary is not null && BinaryReceived is not null)
                {
                    await BinaryReceived.Invoke(frame.Binary).ConfigureAwait(false);
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

    public async Task SendBinaryAsync(byte[] frame)
    {
        if (closed || !IsReady)
        {
            return;
        }

        try
        {
            await SendFrameAsync(0x2, frame, CancellationToken.None).ConfigureAwait(false);
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

        // Echo the input subprotocol when the client requests it: that both marks this
        // connection as the low-latency input channel and tells the client the server
        // understands the split (an old server's response omits it, and the client falls back
        // to the single data connection).
        var protocolHeader = "";
        var requestedProtocols = GetHeaderValue(header, "Sec-WebSocket-Protocol");
        if (requestedProtocols?.Split(',').Select(item => item.Trim()).Contains(TransportChannels.InputSubprotocol) == true)
        {
            IsInputChannel = true;
            protocolHeader = $"Sec-WebSocket-Protocol: {TransportChannels.InputSubprotocol}\r\n";
        }

        var response =
            "HTTP/1.1 101 Switching Protocols\r\n" +
            "Upgrade: websocket\r\n" +
            "Connection: Upgrade\r\n" +
            $"Sec-WebSocket-Accept: {AcceptKey(key)}\r\n" +
            protocolHeader +
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

        var fin = (header[0] & 0x80) != 0;
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

        // Control frames (close/ping/pong) are never fragmented and may interleave with the
        // fragments of a data message, so handle them before any reassembly bookkeeping.
        if (opcode == 0x8)
        {
            return FrameResult.Close;
        }

        if (opcode == 0x9)
        {
            await SendFrameAsync(0xA, payload, token).ConfigureAwait(false);
            return FrameResult.Empty;
        }

        if (opcode == 0xA)
        {
            return FrameResult.Empty;
        }

        return HandleDataFrame(fin, opcode, payload);
    }

    /// Reassembles data frames into messages: a frame with FIN set and a data opcode is a whole
    /// message; otherwise fragments accumulate until the continuation frame with FIN arrives.
    /// Out-of-order fragments (a continuation with nothing started, or a new data opcode while a
    /// message is still open) and oversized reassembled messages close the connection.
    private FrameResult HandleDataFrame(bool fin, byte opcode, byte[] payload)
    {
        switch (opcode)
        {
            case 0x1 or 0x2:
                if (fragmentOpcode is not null)
                {
                    return FrameResult.Close;
                }
                if (fin)
                {
                    return opcode == 0x1
                        ? new FrameResult(false, Encoding.UTF8.GetString(payload))
                        : new FrameResult(false, null, payload);
                }
                fragmentOpcode = opcode;
                fragmentBuffer = new MemoryStream();
                fragmentBuffer.Write(payload);
                return FrameResult.Empty;
            case 0x0:
                if (fragmentOpcode is not { } firstOpcode || fragmentBuffer is null)
                {
                    return FrameResult.Close;
                }
                fragmentBuffer.Write(payload);
                if (fragmentBuffer.Length > ClipboardLimits.MaxWebSocketMessageBytes)
                {
                    return FrameResult.Close;
                }
                if (!fin)
                {
                    return FrameResult.Empty;
                }
                var message = fragmentBuffer.ToArray();
                fragmentOpcode = null;
                fragmentBuffer = null;
                return firstOpcode == 0x1
                    ? new FrameResult(false, Encoding.UTF8.GetString(message))
                    : new FrameResult(false, null, message);
            default:
                return FrameResult.Close;
        }
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

    private readonly record struct FrameResult(bool Closed, string? Text, byte[]? Binary = null)
    {
        public static FrameResult Close => new(true, null);
        public static FrameResult Empty => new(false, null);
    }
}
