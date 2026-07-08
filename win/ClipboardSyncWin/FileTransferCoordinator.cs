using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Threading;

namespace ClipboardSyncWin;

/// Runs chunked, targeted file transfers over the sync transport. The sender streams each file
/// off disk in fixed-size chunks with a small acknowledgement window (so a slow peer applies
/// backpressure instead of ballooning transport buffers), and the receiver streams chunks straight
/// to disk, verifying each file's SHA-256 before anything touches the clipboard. Neither side ever
/// holds more than a few chunks in memory, so there is no file-size limit.
internal sealed class FileTransferCoordinator : IDisposable
{
    public const int ChunkBytes = 1024 * 1024;
    private const int WindowChunks = 4;
    private const int MaxFilesPerTransfer = 200;
    private static readonly TimeSpan InactivityTimeout = TimeSpan.FromSeconds(30);

    public event Action<FileTransferMessage>? MessageReady;
    public event Action<string>? StatusChanged;
    /// Fires when an incoming transfer completed and verified; carries the received files' paths.
    public event Action<List<string>>? FilesReceived;

    private readonly object sync = new();
    private string deviceId = "";
    private OutgoingTransfer? outgoing;
    private readonly Dictionary<string, IncomingTransfer> incoming = [];
    private System.Threading.Timer? watchdog;
    private bool disposed;

    private sealed class OutgoingTransfer
    {
        public string TransferId { get; } = Guid.NewGuid().ToString("N");
        public required string Target { get; init; }
        public required string TargetName { get; init; }
        public required List<(string Path, FileTransferFileInfo Info)> Files { get; init; }
        public long TotalBytes { get; set; }
        public bool Accepted { get; set; }
        public int FileIndex { get; set; }
        public long BytesSentOfCurrentFile { get; set; }
        public FileStream? Stream { get; set; }
        public IncrementalHash Hasher { get; set; } = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        public int NextChunkIndex { get; set; }
        public int LastAckedChunkIndex { get; set; } = -1;
        // Cumulative transfer bytes after each sent chunk, indexed by chunk index, so an ack can
        // be translated into confirmed progress.
        public List<long> CumulativeBytesByChunk { get; } = [];
        public bool FinishedSending { get; set; }
        public DateTimeOffset LastActivity { get; set; } = DateTimeOffset.UtcNow;
        public int LastReportedPercent { get; set; } = -1;
    }

    private sealed class IncomingTransfer
    {
        public required string TransferId { get; init; }
        public required string Origin { get; init; }
        public required string Directory { get; init; }
        public required List<FileTransferFileInfo> Files { get; init; }
        public long TotalBytes { get; set; }
        public int FileIndex { get; set; }
        public long BytesWrittenOfCurrentFile { get; set; }
        public long TotalBytesWritten { get; set; }
        public FileStream? Stream { get; set; }
        public IncrementalHash Hasher { get; set; } = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        public int ExpectedChunkIndex { get; set; }
        public List<string> WrittenPaths { get; } = [];
        public DateTimeOffset LastActivity { get; set; } = DateTimeOffset.UtcNow;
        public int LastReportedPercent { get; set; } = -1;
    }

    // MARK: Public entry points

    /// Must be called before any transfer so replies (accept/ack/done) carry this device's id as
    /// their origin — the receiver side speaks first the moment an offer arrives.
    public void Configure(string deviceId)
    {
        lock (sync)
        {
            this.deviceId = deviceId;
        }
    }

    /// Packages the given local files and offers them to target. One outgoing transfer runs at a
    /// time; starting a new one while another is active is refused so its progress reporting stays
    /// unambiguous.
    public void SendFiles(List<string> paths, string target, string targetName)
    {
        lock (sync)
        {
            if (outgoing is not null)
            {
                StatusChanged?.Invoke(AppText.Text("status.fileTransferBusy"));
                return;
            }

            var files = new List<(string Path, FileTransferFileInfo Info)>();
            foreach (var path in paths.Take(MaxFilesPerTransfer))
            {
                if (!File.Exists(path))
                {
                    StatusChanged?.Invoke(AppText.Text("status.folderUnsupported"));
                    return;
                }
                var name = SafeFileName(Path.GetFileName(path), $"clipboard-file-{files.Count + 1}");
                files.Add((path, new FileTransferFileInfo { Name = name, Size = new FileInfo(path).Length }));
            }
            if (files.Count == 0)
            {
                StatusChanged?.Invoke(AppText.Text("status.copyFilesFirst"));
                return;
            }

            var transfer = new OutgoingTransfer
            {
                Target = target,
                TargetName = targetName,
                Files = files,
                TotalBytes = files.Sum(f => f.Info.Size)
            };
            outgoing = transfer;
            StartWatchdogIfNeeded();
            Send("offer", transfer.TransferId, target, files: files.Select(f => f.Info).ToList());
            StatusChanged?.Invoke(AppText.Text("status.fileTransferStarted"));
        }
    }

    public void Handle(FileTransferMessage message)
    {
        lock (sync)
        {
            if (disposed)
            {
                return;
            }
            switch (message.Kind)
            {
                case "offer":
                    HandleOffer(message);
                    break;
                case "accept":
                    HandleAccept(message);
                    break;
                case "chunk":
                    HandleChunk(message);
                    break;
                case "ack":
                    HandleAck(message);
                    break;
                case "fileDone":
                    HandleFileDone(message);
                    break;
                case "done":
                    HandleDone(message);
                    break;
                case "cancel":
                    HandleCancel(message);
                    break;
            }
        }
    }

    /// Drops every transfer without notifying peers — used when the transport restarts or stops,
    /// at which point the peers are unreachable anyway and their own watchdogs will clean up.
    public void CancelAll()
    {
        lock (sync)
        {
            if (outgoing is { } transfer)
            {
                FinishOutgoing(transfer, failure: null);
            }
            foreach (var incomingTransfer in incoming.Values.ToList())
            {
                AbortIncoming(incomingTransfer, notifyPeer: false, failure: null);
            }
            StopWatchdogIfIdle();
        }
    }

    public void Dispose()
    {
        lock (sync)
        {
            disposed = true;
        }
        CancelAll();
    }

    // MARK: Sender side

    private void HandleAccept(FileTransferMessage message)
    {
        if (outgoing is not { } transfer || transfer.TransferId != message.TransferId || transfer.Accepted)
        {
            return;
        }
        transfer.Accepted = true;
        transfer.LastActivity = DateTimeOffset.UtcNow;
        Pump(transfer);
    }

    private void HandleAck(FileTransferMessage message)
    {
        if (outgoing is not { } transfer
            || transfer.TransferId != message.TransferId
            || message.ChunkIndex is not { } chunkIndex
            || chunkIndex <= transfer.LastAckedChunkIndex
            || chunkIndex >= transfer.NextChunkIndex)
        {
            return;
        }
        transfer.LastAckedChunkIndex = chunkIndex;
        transfer.LastActivity = DateTimeOffset.UtcNow;
        ReportSendProgress(transfer);
        Pump(transfer);
    }

    private void HandleDone(FileTransferMessage message)
    {
        if (outgoing is not { } transfer || transfer.TransferId != message.TransferId)
        {
            return;
        }
        FinishOutgoing(transfer, failure: null);
        StatusChanged?.Invoke(AppText.Format("status.filesSent", transfer.TargetName));
    }

    /// Sends chunks until the acknowledgement window is full or every file has been read. Called
    /// again on each ack, so throughput self-paces to whatever the receiver confirms.
    private void Pump(OutgoingTransfer transfer)
    {
        if (!ReferenceEquals(outgoing, transfer) || !transfer.Accepted || transfer.FinishedSending)
        {
            return;
        }

        while (transfer.NextChunkIndex - transfer.LastAckedChunkIndex - 1 < WindowChunks)
        {
            if (transfer.FileIndex >= transfer.Files.Count)
            {
                transfer.FinishedSending = true;
                return;
            }

            var file = transfer.Files[transfer.FileIndex];
            try
            {
                if (transfer.Stream is null)
                {
                    transfer.Stream = new FileStream(file.Path, FileMode.Open, FileAccess.Read, FileShare.Read);
                    transfer.Hasher = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
                    transfer.BytesSentOfCurrentFile = 0;
                }

                var buffer = new byte[ChunkBytes];
                var read = transfer.Stream.Read(buffer, 0, buffer.Length);
                if (read == 0)
                {
                    // End of file: its byte count must match what the offer declared, otherwise
                    // the file changed on disk mid-transfer and the receiver's bookkeeping is off.
                    if (transfer.BytesSentOfCurrentFile != file.Info.Size)
                    {
                        throw new InvalidOperationException($"file changed while sending: {file.Info.Name}");
                    }
                    transfer.Stream.Dispose();
                    transfer.Stream = null;
                    var digest = Convert.ToHexString(transfer.Hasher.GetHashAndReset()).ToLowerInvariant();
                    Send("fileDone", transfer.TransferId, transfer.Target, fileIndex: transfer.FileIndex, sha256: digest);
                    transfer.FileIndex++;
                    continue;
                }

                if (transfer.BytesSentOfCurrentFile + read > file.Info.Size)
                {
                    throw new InvalidOperationException($"file changed while sending: {file.Info.Name}");
                }
                transfer.Hasher.AppendData(buffer, 0, read);
                transfer.BytesSentOfCurrentFile += read;
                var cumulative = (transfer.CumulativeBytesByChunk.Count > 0 ? transfer.CumulativeBytesByChunk[^1] : 0) + read;
                transfer.CumulativeBytesByChunk.Add(cumulative);
                Send(
                    "chunk",
                    transfer.TransferId,
                    transfer.Target,
                    fileIndex: transfer.FileIndex,
                    chunkIndex: transfer.NextChunkIndex,
                    dataBase64: Convert.ToBase64String(buffer, 0, read));
                transfer.NextChunkIndex++;
            }
            catch (Exception ex)
            {
                Send("cancel", transfer.TransferId, transfer.Target, reason: ex.Message);
                FinishOutgoing(transfer, failure: ex.Message);
                return;
            }
        }
    }

    private void ReportSendProgress(OutgoingTransfer transfer)
    {
        if (transfer.TotalBytes <= 0 || transfer.LastAckedChunkIndex < 0)
        {
            return;
        }
        var ackedBytes = transfer.CumulativeBytesByChunk[transfer.LastAckedChunkIndex];
        var percent = (int)(ackedBytes * 100 / transfer.TotalBytes);
        if (percent == transfer.LastReportedPercent)
        {
            return;
        }
        transfer.LastReportedPercent = percent;
        StatusChanged?.Invoke(AppText.Format("status.fileSendProgress", transfer.TargetName, percent));
    }

    private void FinishOutgoing(OutgoingTransfer transfer, string? failure)
    {
        if (!ReferenceEquals(outgoing, transfer))
        {
            return;
        }
        transfer.Stream?.Dispose();
        transfer.Stream = null;
        outgoing = null;
        if (failure is not null)
        {
            StatusChanged?.Invoke(AppText.Format("status.fileTransferFailed", failure));
        }
        StopWatchdogIfIdle();
    }

    // MARK: Receiver side

    private void HandleOffer(FileTransferMessage message)
    {
        if (incoming.ContainsKey(message.TransferId)
            || message.Files is not { Count: > 0 and <= MaxFilesPerTransfer } files
            || files.Any(f => f.Size < 0))
        {
            return;
        }

        var directory = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "ClipboardSync",
            "Received",
            Guid.NewGuid().ToString("N"));
        try
        {
            Directory.CreateDirectory(directory);
        }
        catch
        {
            Send("cancel", message.TransferId, message.Origin, reason: "cannot create destination");
            return;
        }

        // Sanitize names up front, de-duplicating collisions so two offered "a.txt" entries don't
        // silently stream into one file.
        var seenNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var sanitized = files.Select((file, index) =>
        {
            var name = SafeFileName(file.Name, $"clipboard-file-{index + 1}");
            while (!seenNames.Add(name))
            {
                name = $"{index + 1}-{name}";
            }
            return new FileTransferFileInfo { Name = name, Size = file.Size };
        }).ToList();

        var transfer = new IncomingTransfer
        {
            TransferId = message.TransferId,
            Origin = message.Origin,
            Directory = directory,
            Files = sanitized,
            TotalBytes = sanitized.Sum(f => f.Size)
        };
        incoming[message.TransferId] = transfer;
        StartWatchdogIfNeeded();
        Send("accept", transfer.TransferId, transfer.Origin);
    }

    private void HandleChunk(FileTransferMessage message)
    {
        if (!incoming.TryGetValue(message.TransferId, out var transfer) || transfer.Origin != message.Origin)
        {
            return;
        }

        byte[] data;
        try
        {
            data = Convert.FromBase64String(message.DataBase64 ?? "");
        }
        catch
        {
            AbortIncoming(transfer, notifyPeer: true, failure: "protocol error");
            return;
        }

        if (message.ChunkIndex != transfer.ExpectedChunkIndex
            || message.FileIndex != transfer.FileIndex
            || transfer.FileIndex >= transfer.Files.Count
            || data.Length == 0
            || data.Length > ChunkBytes
            || transfer.BytesWrittenOfCurrentFile + data.Length > transfer.Files[transfer.FileIndex].Size)
        {
            AbortIncoming(transfer, notifyPeer: true, failure: "protocol error");
            return;
        }

        try
        {
            transfer.Stream ??= OpenNextFile(transfer);
            transfer.Stream.Write(data, 0, data.Length);
        }
        catch (Exception ex)
        {
            AbortIncoming(transfer, notifyPeer: true, failure: ex.Message);
            return;
        }

        transfer.Hasher.AppendData(data);
        transfer.BytesWrittenOfCurrentFile += data.Length;
        transfer.TotalBytesWritten += data.Length;
        transfer.ExpectedChunkIndex++;
        transfer.LastActivity = DateTimeOffset.UtcNow;
        Send("ack", transfer.TransferId, transfer.Origin, chunkIndex: message.ChunkIndex);
        ReportReceiveProgress(transfer);
    }

    private void HandleFileDone(FileTransferMessage message)
    {
        if (!incoming.TryGetValue(message.TransferId, out var transfer) || transfer.Origin != message.Origin)
        {
            return;
        }
        if (message.FileIndex != transfer.FileIndex || transfer.FileIndex >= transfer.Files.Count)
        {
            AbortIncoming(transfer, notifyPeer: true, failure: "protocol error");
            return;
        }

        var file = transfer.Files[transfer.FileIndex];
        try
        {
            // A zero-byte file arrives as a bare fileDone with no preceding chunk; materialize it.
            transfer.Stream ??= OpenNextFile(transfer);
            transfer.Stream.Dispose();
            transfer.Stream = null;
        }
        catch (Exception ex)
        {
            AbortIncoming(transfer, notifyPeer: true, failure: ex.Message);
            return;
        }

        var digest = Convert.ToHexString(transfer.Hasher.GetHashAndReset()).ToLowerInvariant();
        if (transfer.BytesWrittenOfCurrentFile != file.Size
            || message.Sha256 is not { } expected
            || !digest.Equals(expected, StringComparison.OrdinalIgnoreCase))
        {
            AbortIncoming(transfer, notifyPeer: true, failure: "checksum mismatch");
            return;
        }

        transfer.FileIndex++;
        transfer.BytesWrittenOfCurrentFile = 0;
        transfer.LastActivity = DateTimeOffset.UtcNow;

        if (transfer.FileIndex == transfer.Files.Count)
        {
            incoming.Remove(transfer.TransferId);
            StopWatchdogIfIdle();
            Send("done", transfer.TransferId, transfer.Origin);
            FilesReceived?.Invoke(transfer.WrittenPaths);
        }
    }

    private void HandleCancel(FileTransferMessage message)
    {
        if (incoming.TryGetValue(message.TransferId, out var incomingTransfer) && incomingTransfer.Origin == message.Origin)
        {
            AbortIncoming(incomingTransfer, notifyPeer: false, failure: message.Reason ?? "cancelled by sender");
        }
        if (outgoing is { } outgoingTransfer && outgoingTransfer.TransferId == message.TransferId)
        {
            FinishOutgoing(outgoingTransfer, failure: message.Reason ?? "cancelled by receiver");
        }
    }

    private FileStream OpenNextFile(IncomingTransfer transfer)
    {
        var path = Path.Combine(transfer.Directory, transfer.Files[transfer.FileIndex].Name);
        var stream = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None);
        transfer.WrittenPaths.Add(path);
        return stream;
    }

    private void ReportReceiveProgress(IncomingTransfer transfer)
    {
        if (transfer.TotalBytes <= 0)
        {
            return;
        }
        var percent = (int)(transfer.TotalBytesWritten * 100 / transfer.TotalBytes);
        if (percent == transfer.LastReportedPercent)
        {
            return;
        }
        transfer.LastReportedPercent = percent;
        StatusChanged?.Invoke(AppText.Format("status.fileReceiveProgress", percent));
    }

    private void AbortIncoming(IncomingTransfer transfer, bool notifyPeer, string? failure)
    {
        if (!incoming.Remove(transfer.TransferId))
        {
            return;
        }
        transfer.Stream?.Dispose();
        transfer.Stream = null;
        try
        {
            Directory.Delete(transfer.Directory, recursive: true);
        }
        catch
        {
            // Best effort; a stray partial directory is harmless.
        }
        if (notifyPeer)
        {
            Send("cancel", transfer.TransferId, transfer.Origin, reason: failure);
        }
        if (failure is not null)
        {
            StatusChanged?.Invoke(AppText.Format("status.fileTransferFailed", failure));
        }
        StopWatchdogIfIdle();
    }

    // MARK: Watchdog

    /// Transfers ride the same silent-drop transport as everything else, so a vanished peer (or a
    /// peer that never understood the offer) must be detected by inactivity rather than an error.
    private void StartWatchdogIfNeeded()
    {
        watchdog ??= new System.Threading.Timer(_ => CheckTimeouts(), null, TimeSpan.FromSeconds(5), TimeSpan.FromSeconds(5));
    }

    private void StopWatchdogIfIdle()
    {
        if (outgoing is not null || incoming.Count > 0)
        {
            return;
        }
        watchdog?.Dispose();
        watchdog = null;
    }

    private void CheckTimeouts()
    {
        lock (sync)
        {
            var cutoff = DateTimeOffset.UtcNow - InactivityTimeout;
            if (outgoing is { } transfer && transfer.LastActivity < cutoff)
            {
                Send("cancel", transfer.TransferId, transfer.Target, reason: "timed out");
                FinishOutgoing(transfer, failure: "timed out");
            }
            foreach (var incomingTransfer in incoming.Values.Where(t => t.LastActivity < cutoff).ToList())
            {
                AbortIncoming(incomingTransfer, notifyPeer: true, failure: "timed out");
            }
        }
    }

    // MARK: Helpers

    private void Send(
        string kind,
        string transferId,
        string target,
        List<FileTransferFileInfo>? files = null,
        int? fileIndex = null,
        int? chunkIndex = null,
        string? dataBase64 = null,
        string? sha256 = null,
        string? reason = null)
    {
        MessageReady?.Invoke(new FileTransferMessage
        {
            Type = "file",
            Origin = deviceId,
            Target = target,
            Kind = kind,
            TransferId = transferId,
            Files = files,
            FileIndex = fileIndex,
            ChunkIndex = chunkIndex,
            DataBase64 = dataBase64,
            Sha256 = sha256,
            Reason = reason,
            SentAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0
        });
    }

    private static string SafeFileName(string? name, string fallback)
    {
        var fileName = Path.GetFileName(name ?? "");
        if (string.IsNullOrWhiteSpace(fileName))
        {
            return fallback;
        }

        foreach (var invalid in Path.GetInvalidFileNameChars())
        {
            fileName = fileName.Replace(invalid, '_');
        }

        fileName = fileName.Trim();
        return string.IsNullOrWhiteSpace(fileName) || fileName is "." or ".." ? fallback : fileName;
    }
}
