using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Threading;
using System.Threading.Channels;
using System.Threading.Tasks;

namespace ClipboardSyncWin;

/// Runs the port-forward data plane. For every enabled rule whose "In" side is this device it
/// listens on that TCP port, and tunnels each accepted connection to the rule's "Out" device as
/// encrypted "tunnel" messages over the existing sync transport. When a peer opens a tunnel into
/// this device, it dials 127.0.0.1:&lt;outPort&gt; and streams both directions until either end closes.
internal sealed class PortForwardCoordinator : IDisposable
{
    public event Action<TunnelMessage>? MessageReady;
    public event Action<string>? StatusChanged;
    /// Fires whenever this device's own listen state changes - a rule starts listening, fails to
    /// bind, or leaves the local In set. Carries the full current set of local rule statuses so the
    /// app can refresh the dialog and broadcast it to peers.
    public event Action<List<PortForwardStatus>>? StatusesChanged;

    private readonly object gate = new();
    private readonly Dictionary<int, RuleListener> listeners = [];
    private readonly Dictionary<string, Tunnel> tunnels = [];
    /// Live listen state for rules this device is the In side of, keyed by rule id.
    private readonly Dictionary<string, PortForwardStatus> ruleStatuses = [];
    private string deviceId = "";
    private bool transportReady;
    private HashSet<string> onlinePeers = [];
    private bool disposed;
    private const int ChunkBytes = 60 * 1024;

    private sealed class RuleListener
    {
        public required PortForwardRule Rule { get; init; }
        public required TcpListener Listener { get; init; }
        public required CancellationTokenSource Cancellation { get; init; }
    }

    private sealed class Tunnel
    {
        public required string ConnectionId { get; init; }
        public required string PeerDeviceId { get; init; }
        public required TcpClient Client { get; init; }
        /// Peer data is queued here and drained by one writer task per tunnel, which starts only
        /// once the local socket is connected - that both preserves chunk order and buffers chunks
        /// that race ahead of the "Out" side's dial.
        public Channel<byte[]> Outgoing { get; } = Channel.CreateUnbounded<byte[]>();
    }

    /// Reconciles the listener set with the current rule table. Listeners exist only while the
    /// transport is running; each accepted connection additionally requires the rule's "Out"
    /// device to be online right now, otherwise it is refused immediately.
    public void Update(string deviceId, List<PortForwardRule> rules, bool transportReady, HashSet<string> onlinePeers)
    {
        lock (gate)
        {
            if (disposed)
            {
                return;
            }
            this.deviceId = deviceId;
            this.onlinePeers = onlinePeers;
            this.transportReady = transportReady;

            if (!transportReady)
            {
                TeardownAllLocked();
                return;
            }

            var desired = rules
                .Where(rule => rule.InDeviceId == deviceId && rule.Enabled && rule.InPort is >= 1 and <= 65_535)
                .GroupBy(rule => rule.InPort)
                .ToDictionary(group => group.Key, group => group.First());

            var statusesChanged = false;
            foreach (var (port, existing) in listeners.ToList())
            {
                if (!desired.TryGetValue(port, out var rule) || rule != existing.Rule)
                {
                    StopListenerLocked(existing, port);
                    // A rule that was edited (port/host/LAN) restarts its listener; drop its stale
                    // status so it re-reports on the new bind.
                    statusesChanged |= ruleStatuses.Remove(existing.Rule.Id);
                }
            }

            // Drop status for rules no longer in the local-enabled-In set (disabled, deleted, or
            // moved to another device).
            var desiredIds = desired.Values.Select(rule => rule.Id).ToHashSet();
            foreach (var staleId in ruleStatuses.Keys.Where(id => !desiredIds.Contains(id)).ToList())
            {
                statusesChanged |= ruleStatuses.Remove(staleId);
            }

            foreach (var (port, rule) in desired)
            {
                if (!listeners.ContainsKey(port))
                {
                    StartListenerLocked(rule, port);
                    statusesChanged = true;
                }
            }

            if (statusesChanged)
            {
                NotifyStatusesLocked();
            }
        }
    }

    private void SetStatusLocked(string id, bool ok, string? reason)
    {
        if (ruleStatuses.TryGetValue(id, out var existing) && existing.Ok == ok && existing.Reason == reason)
        {
            return;
        }
        ruleStatuses[id] = new PortForwardStatus { Id = id, Ok = ok, Reason = reason };
        NotifyStatusesLocked();
    }

    private void NotifyStatusesLocked()
    {
        StatusesChanged?.Invoke(ruleStatuses.Values.Select(s => new PortForwardStatus { Id = s.Id, Ok = s.Ok, Reason = s.Reason }).ToList());
    }

    public void Handle(TunnelMessage message)
    {
        switch (message.Kind)
        {
            case "open":
                HandleOpen(message);
                break;
            case "data":
                HandleData(message);
                break;
            case "close":
                RemoveTunnel(message.ConnectionId, notifyPeer: false, reason: null);
                break;
        }
    }

    public void Stop()
    {
        lock (gate)
        {
            transportReady = false;
            TeardownAllLocked();
        }
    }

    public void Dispose()
    {
        lock (gate)
        {
            disposed = true;
            TeardownAllLocked();
        }
    }

    private void TeardownAllLocked()
    {
        foreach (var (port, entry) in listeners.ToList())
        {
            StopListenerLocked(entry, port);
        }
        foreach (var connectionId in tunnels.Keys.ToList())
        {
            RemoveTunnelLocked(connectionId, notifyPeer: false, reason: null);
        }
        if (ruleStatuses.Count > 0)
        {
            ruleStatuses.Clear();
            NotifyStatusesLocked();
        }
    }

    private void StopListenerLocked(RuleListener entry, int port)
    {
        entry.Cancellation.Cancel();
        try
        {
            entry.Listener.Stop();
        }
        catch
        {
            // Already stopped.
        }
        listeners.Remove(port);
    }

    // In side (local listener).

    private void StartListenerLocked(PortForwardRule rule, int port)
    {
        // Loopback keeps the forwarded port reachable only from this machine; Any (0.0.0.0) exposes
        // it to other machines on the LAN.
        var listener = new TcpListener(rule.InAllowLan ? IPAddress.Any : IPAddress.Loopback, port);
        try
        {
            listener.Start();
        }
        catch (SocketException ex)
        {
            // A privileged/reserved port that needs elevation gets a friendlier reason; anything
            // else (port in use, etc.) shows the raw OS reason. The reason is stored as the rule's
            // status (shown red with a tooltip in the dialog) and echoed to the tray status line.
            string reason;
            string statusLine;
            if (ex.SocketErrorCode == SocketError.AccessDenied)
            {
                reason = AppText.Text("forward.reasonPrivileged");
                statusLine = AppText.Format("status.forwardListenPermission", port);
            }
            else
            {
                reason = ex.Message;
                statusLine = AppText.Format("status.forwardListenFailed", port, ex.Message);
            }
            StatusChanged?.Invoke(statusLine);
            SetStatusLocked(rule.Id, ok: false, reason: reason);
            return;
        }

        var cancellation = new CancellationTokenSource();
        listeners[port] = new RuleListener { Rule = rule, Listener = listener, Cancellation = cancellation };
        SetStatusLocked(rule.Id, ok: true, reason: null);
        _ = Task.Run(() => AcceptLoop(rule, listener, cancellation.Token));
    }

    private async Task AcceptLoop(PortForwardRule rule, TcpListener listener, CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            TcpClient client;
            try
            {
                client = await listener.AcceptTcpClientAsync(token).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                return;
            }
            catch (ObjectDisposedException)
            {
                return;
            }
            catch (SocketException)
            {
                continue;
            }

            Accept(client, rule);
        }
    }

    private void Accept(TcpClient client, PortForwardRule rule)
    {
        Tunnel tunnel;
        lock (gate)
        {
            if (disposed || !transportReady || !onlinePeers.Contains(rule.OutDeviceId))
            {
                try
                {
                    client.Close();
                }
                catch
                {
                    // Refused before any traffic; nothing to clean up.
                }
                return;
            }

            tunnel = new Tunnel
            {
                ConnectionId = Guid.NewGuid().ToString(),
                PeerDeviceId = rule.OutDeviceId,
                Client = client
            };
            tunnels[tunnel.ConnectionId] = tunnel;
        }

        Send(tunnel, "open", host: rule.OutHost, port: rule.OutPort);
        _ = Task.Run(() => ReadLoop(tunnel));
        _ = Task.Run(() => WriteLoop(tunnel));
    }

    // Out side (local dial).

    private void HandleOpen(TunnelMessage message)
    {
        if (message.Port is not (>= 1 and <= 65_535) || string.IsNullOrEmpty(message.ConnectionId))
        {
            SendClose(message.ConnectionId, message.Origin, "invalid port");
            return;
        }

        var tunnel = new Tunnel
        {
            ConnectionId = message.ConnectionId,
            PeerDeviceId = message.Origin,
            Client = new TcpClient()
        };
        lock (gate)
        {
            if (disposed || !transportReady || tunnels.ContainsKey(message.ConnectionId))
            {
                tunnel.Client.Dispose();
                return;
            }
            tunnels[message.ConnectionId] = tunnel;
        }

        var host = string.IsNullOrEmpty(message.Host) ? "127.0.0.1" : message.Host;
        _ = Task.Run(async () =>
        {
            try
            {
                await tunnel.Client.ConnectAsync(host, message.Port.Value).ConfigureAwait(false);
            }
            catch
            {
                RemoveTunnel(tunnel.ConnectionId, notifyPeer: true, reason: "connection failed");
                return;
            }
            _ = Task.Run(() => ReadLoop(tunnel));
            _ = Task.Run(() => WriteLoop(tunnel));
        });
    }

    private void HandleData(TunnelMessage message)
    {
        Tunnel? tunnel;
        lock (gate)
        {
            tunnels.TryGetValue(message.ConnectionId, out tunnel);
        }
        if (tunnel is null || message.DataBase64 is null)
        {
            return;
        }

        byte[] payload;
        try
        {
            payload = Convert.FromBase64String(message.DataBase64);
        }
        catch (FormatException)
        {
            return;
        }
        tunnel.Outgoing.Writer.TryWrite(payload);
    }

    // Shared stream plumbing.

    private async Task ReadLoop(Tunnel tunnel)
    {
        var buffer = new byte[ChunkBytes];
        try
        {
            var stream = tunnel.Client.GetStream();
            while (true)
            {
                var count = await stream.ReadAsync(buffer).ConfigureAwait(false);
                if (count <= 0)
                {
                    break;
                }
                Send(tunnel, "data", dataBase64: Convert.ToBase64String(buffer, 0, count));
            }
        }
        catch
        {
            // Fall through to teardown.
        }
        RemoveTunnel(tunnel.ConnectionId, notifyPeer: true, reason: null);
    }

    private async Task WriteLoop(Tunnel tunnel)
    {
        try
        {
            var stream = tunnel.Client.GetStream();
            await foreach (var payload in tunnel.Outgoing.Reader.ReadAllAsync().ConfigureAwait(false))
            {
                await stream.WriteAsync(payload).ConfigureAwait(false);
            }
        }
        catch
        {
            RemoveTunnel(tunnel.ConnectionId, notifyPeer: true, reason: "write failed");
        }
    }

    private void RemoveTunnel(string connectionId, bool notifyPeer, string? reason)
    {
        lock (gate)
        {
            RemoveTunnelLocked(connectionId, notifyPeer, reason);
        }
    }

    private void RemoveTunnelLocked(string connectionId, bool notifyPeer, string? reason)
    {
        if (!tunnels.Remove(connectionId, out var tunnel))
        {
            return;
        }
        tunnel.Outgoing.Writer.TryComplete();
        try
        {
            tunnel.Client.Close();
        }
        catch
        {
            // Already closed.
        }
        if (notifyPeer)
        {
            SendClose(connectionId, tunnel.PeerDeviceId, reason);
        }
    }

    private void Send(Tunnel tunnel, string kind, string? host = null, int? port = null, string? dataBase64 = null)
    {
        MessageReady?.Invoke(new TunnelMessage
        {
            Type = "tunnel",
            Origin = deviceId,
            Target = tunnel.PeerDeviceId,
            Kind = kind,
            ConnectionId = tunnel.ConnectionId,
            Host = host,
            Port = port,
            DataBase64 = dataBase64,
            SentAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0
        });
    }

    private void SendClose(string connectionId, string peerDeviceId, string? reason)
    {
        MessageReady?.Invoke(new TunnelMessage
        {
            Type = "tunnel",
            Origin = deviceId,
            Target = peerDeviceId,
            Kind = "close",
            ConnectionId = connectionId,
            Reason = reason,
            SentAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0
        });
    }
}
