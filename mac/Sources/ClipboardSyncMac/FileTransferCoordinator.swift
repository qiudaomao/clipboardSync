import CryptoKit
import Foundation

/// Runs chunked, targeted file transfers over the sync transport. The sender streams each file
/// off disk in fixed-size chunks with a small acknowledgement window (so a slow peer applies
/// backpressure instead of ballooning transport buffers), and the receiver streams chunks straight
/// to disk, verifying each file's SHA-256 before anything touches the clipboard. Neither side ever
/// holds more than a few chunks in memory, so there is no file-size limit.
final class FileTransferCoordinator {
    var onSend: ((FileTransferMessage) -> Void)?
    /// Emits a `chunk` as its metadata (with `dataBase64` nil) plus the raw bytes, for the caller
    /// to ship as a binary `BulkFrame`. Chunks are 1 MiB and sent back to back, so keeping them off
    /// the base64+JSON envelope path is the whole point; every other file message stays on `onSend`.
    var onSendChunk: ((FileTransferMessage, Data) -> Void)?
    var onStatus: ((String) -> Void)?
    /// Fires when an incoming transfer completed and verified; carries the received files' URLs.
    var onFilesReceived: (([URL]) -> Void)?

    private let queue = DispatchQueue(label: "ClipboardSyncMac.fileTransfer")
    private var deviceId = ""
    private var outgoing: OutgoingTransfer?
    private var incoming: [String: IncomingTransfer] = [:]
    private var watchdog: DispatchSourceTimer?

    static let chunkBytes = 1024 * 1024
    private static let windowChunks = 4
    private static let inactivityTimeout: TimeInterval = 30
    private static let maxFilesPerTransfer = 200

    private final class OutgoingTransfer {
        let transferId = UUID().uuidString
        let target: String
        let targetName: String
        let files: [(url: URL, info: FileTransferFileInfo)]
        let totalBytes: Int64
        var accepted = false
        var fileIndex = 0
        var bytesSentOfCurrentFile: Int64 = 0
        var handle: FileHandle?
        var hasher = SHA256()
        var nextChunkIndex = 0
        var lastAckedChunkIndex = -1
        /// Cumulative transfer bytes after each sent chunk, indexed by chunk index, so an ack can
        /// be translated into confirmed progress.
        var cumulativeBytesByChunk: [Int64] = []
        var finishedSending = false
        var lastActivity = Date()
        var lastReportedPercent = -1

        init(target: String, targetName: String, files: [(url: URL, info: FileTransferFileInfo)]) {
            self.target = target
            self.targetName = targetName
            self.files = files
            self.totalBytes = files.reduce(0) { $0 + $1.info.size }
        }
    }

    private final class IncomingTransfer {
        let transferId: String
        let origin: String
        let directory: URL
        let files: [FileTransferFileInfo]
        let totalBytes: Int64
        var fileIndex = 0
        var bytesWrittenOfCurrentFile: Int64 = 0
        var totalBytesWritten: Int64 = 0
        var handle: FileHandle?
        var hasher = SHA256()
        var expectedChunkIndex = 0
        var writtenURLs: [URL] = []
        var lastActivity = Date()
        var lastReportedPercent = -1

        init(transferId: String, origin: String, directory: URL, files: [FileTransferFileInfo]) {
            self.transferId = transferId
            self.origin = origin
            self.directory = directory
            self.files = files
            self.totalBytes = files.reduce(0) { $0 + $1.size }
        }
    }

    // MARK: - Public entry points

    /// Must be called before any transfer so replies (`accept`/`ack`/`done`) carry this device's
    /// id as their origin — the receiver side speaks first the moment an offer arrives.
    func configure(deviceId: String) {
        queue.async {
            self.deviceId = deviceId
        }
    }

    /// Packages the given local files and offers them to `target`. One outgoing transfer runs at a
    /// time; starting a new one while another is active is refused so its progress reporting stays
    /// unambiguous.
    func sendFiles(_ urls: [URL], to target: String, targetName: String) {
        queue.async {
            guard self.outgoing == nil else {
                self.onStatus?(AppText.text("status.fileTransferBusy"))
                return
            }

            var files: [(url: URL, info: FileTransferFileInfo)] = []
            for url in urls.prefix(Self.maxFilesPerTransfer) {
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values?.isRegularFile == true else {
                    self.onStatus?(AppText.text("status.folderUnsupported"))
                    return
                }
                let name = Self.safeFileName(url.lastPathComponent, fallback: "clipboard-file-\(files.count + 1)")
                files.append((url, FileTransferFileInfo(name: name, size: Int64(values?.fileSize ?? 0))))
            }
            guard !files.isEmpty else {
                self.onStatus?(AppText.text("status.copyFilesFirst"))
                return
            }

            let transfer = OutgoingTransfer(target: target, targetName: targetName, files: files)
            self.outgoing = transfer
            self.startWatchdogIfNeeded()
            self.send(kind: "offer", transferId: transfer.transferId, target: target, files: files.map(\.info))
            self.onStatus?(AppText.text("status.fileTransferStarted"))
        }
    }

    func handle(_ message: FileTransferMessage) {
        queue.async {
            switch message.kind {
            case "offer":
                self.handleOffer(message)
            case "accept":
                self.handleAccept(message)
            case "chunk":
                // Chunks now arrive as binary BulkFrames via handleChunk(_:data:); a `chunk` on
                // the JSON path is a stale or hostile peer and is ignored.
                break
            case "ack":
                self.handleAck(message)
            case "fileDone":
                self.handleFileDone(message)
            case "done":
                self.handleDone(message)
            case "cancel":
                self.handleCancel(message)
            default:
                break
            }
        }
    }

    /// Drops every transfer without notifying peers — used when the transport restarts or stops,
    /// at which point the peers are unreachable anyway and their own watchdogs will clean up.
    func cancelAll() {
        queue.async {
            if let transfer = self.outgoing {
                self.finishOutgoing(transfer, failure: nil)
            }
            for transfer in Array(self.incoming.values) {
                self.abortIncoming(transfer, notifyPeer: false, failure: nil)
            }
            self.stopWatchdogIfIdle()
        }
    }

    // MARK: - Sender side

    private func handleAccept(_ message: FileTransferMessage) {
        guard let transfer = outgoing, transfer.transferId == message.transferId, !transfer.accepted else {
            return
        }
        transfer.accepted = true
        transfer.lastActivity = Date()
        pump(transfer)
    }

    private func handleAck(_ message: FileTransferMessage) {
        guard
            let transfer = outgoing,
            transfer.transferId == message.transferId,
            let chunkIndex = message.chunkIndex,
            chunkIndex > transfer.lastAckedChunkIndex,
            chunkIndex < transfer.nextChunkIndex
        else {
            return
        }
        transfer.lastAckedChunkIndex = chunkIndex
        transfer.lastActivity = Date()
        reportSendProgress(transfer)
        pump(transfer)
    }

    private func handleDone(_ message: FileTransferMessage) {
        guard let transfer = outgoing, transfer.transferId == message.transferId else {
            return
        }
        finishOutgoing(transfer, failure: nil)
        onStatus?(AppText.format("status.filesSent", transfer.targetName))
    }

    /// Sends chunks until the acknowledgement window is full or every file has been read. Called
    /// again on each ack, so throughput self-paces to whatever the receiver confirms.
    private func pump(_ transfer: OutgoingTransfer) {
        guard outgoing === transfer, transfer.accepted, !transfer.finishedSending else {
            return
        }

        while transfer.nextChunkIndex - transfer.lastAckedChunkIndex - 1 < Self.windowChunks {
            guard transfer.fileIndex < transfer.files.count else {
                transfer.finishedSending = true
                return
            }

            let file = transfer.files[transfer.fileIndex]
            do {
                if transfer.handle == nil {
                    transfer.handle = try FileHandle(forReadingFrom: file.url)
                    transfer.hasher = SHA256()
                    transfer.bytesSentOfCurrentFile = 0
                }

                let data = try transfer.handle?.read(upToCount: Self.chunkBytes) ?? Data()
                if data.isEmpty {
                    // End of file: its byte count must match what the offer declared, otherwise
                    // the file changed on disk mid-transfer and the receiver's bookkeeping is off.
                    guard transfer.bytesSentOfCurrentFile == file.info.size else {
                        throw TransferError.fileChanged(file.info.name)
                    }
                    try transfer.handle?.close()
                    transfer.handle = nil
                    let digest = transfer.hasher.finalize()
                    send(
                        kind: "fileDone",
                        transferId: transfer.transferId,
                        target: transfer.target,
                        fileIndex: transfer.fileIndex,
                        sha256: Self.hex(digest)
                    )
                    transfer.fileIndex += 1
                    continue
                }

                guard transfer.bytesSentOfCurrentFile + Int64(data.count) <= file.info.size else {
                    throw TransferError.fileChanged(file.info.name)
                }
                transfer.hasher.update(data: data)
                transfer.bytesSentOfCurrentFile += Int64(data.count)
                let cumulative = (transfer.cumulativeBytesByChunk.last ?? 0) + Int64(data.count)
                transfer.cumulativeBytesByChunk.append(cumulative)
                onSendChunk?(
                    FileTransferMessage(
                        type: "file",
                        origin: deviceId,
                        target: transfer.target,
                        kind: "chunk",
                        transferId: transfer.transferId,
                        files: nil,
                        fileIndex: transfer.fileIndex,
                        chunkIndex: transfer.nextChunkIndex,
                        dataBase64: nil,
                        sha256: nil,
                        reason: nil,
                        sentAt: Date().timeIntervalSince1970
                    ),
                    data
                )
                transfer.nextChunkIndex += 1
            } catch {
                let reason = (error as? TransferError)?.reason ?? error.localizedDescription
                send(kind: "cancel", transferId: transfer.transferId, target: transfer.target, reason: reason)
                finishOutgoing(transfer, failure: reason)
                return
            }
        }
    }

    private func reportSendProgress(_ transfer: OutgoingTransfer) {
        guard transfer.totalBytes > 0, transfer.lastAckedChunkIndex >= 0 else {
            return
        }
        let ackedBytes = transfer.cumulativeBytesByChunk[transfer.lastAckedChunkIndex]
        let percent = Int(ackedBytes * 100 / transfer.totalBytes)
        guard percent != transfer.lastReportedPercent else {
            return
        }
        transfer.lastReportedPercent = percent
        onStatus?(AppText.format("status.fileSendProgress", transfer.targetName, percent))
    }

    private func finishOutgoing(_ transfer: OutgoingTransfer, failure: String?) {
        guard outgoing === transfer else {
            return
        }
        try? transfer.handle?.close()
        transfer.handle = nil
        outgoing = nil
        if let failure {
            onStatus?(AppText.format("status.fileTransferFailed", failure))
        }
        stopWatchdogIfIdle()
    }

    // MARK: - Receiver side

    private func handleOffer(_ message: FileTransferMessage) {
        guard
            incoming[message.transferId] == nil,
            let files = message.files,
            !files.isEmpty,
            files.count <= Self.maxFilesPerTransfer,
            files.allSatisfy({ $0.size >= 0 })
        else {
            return
        }

        let fileManager = FileManager.default
        guard let supportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            send(kind: "cancel", transferId: message.transferId, target: message.origin, reason: "no destination directory")
            return
        }
        let directory = supportURL
            .appendingPathComponent("ClipboardSync", isDirectory: true)
            .appendingPathComponent("Received", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            send(kind: "cancel", transferId: message.transferId, target: message.origin, reason: "cannot create destination")
            return
        }

        // Sanitize names up front, de-duplicating collisions so two offered "a.txt" entries don't
        // silently stream into one file.
        var seenNames: Set<String> = []
        let sanitized = files.enumerated().map { index, file -> FileTransferFileInfo in
            var name = Self.safeFileName(file.name, fallback: "clipboard-file-\(index + 1)")
            while !seenNames.insert(name).inserted {
                name = "\(index + 1)-\(name)"
            }
            return FileTransferFileInfo(name: name, size: file.size)
        }

        let transfer = IncomingTransfer(
            transferId: message.transferId,
            origin: message.origin,
            directory: directory,
            files: sanitized
        )
        incoming[message.transferId] = transfer
        startWatchdogIfNeeded()
        send(kind: "accept", transferId: transfer.transferId, target: transfer.origin)
    }

    /// Receives a `chunk` decoded from a binary `BulkFrame`: the metadata message plus the raw
    /// bytes, which go straight to disk with no base64 decode.
    func handleChunk(_ message: FileTransferMessage, data: Data) {
        queue.async {
            self.handleChunkLocked(message, data: data)
        }
    }

    private func handleChunkLocked(_ message: FileTransferMessage, data: Data) {
        guard let transfer = incoming[message.transferId], transfer.origin == message.origin else {
            return
        }
        guard
            let chunkIndex = message.chunkIndex,
            chunkIndex == transfer.expectedChunkIndex,
            let fileIndex = message.fileIndex,
            fileIndex == transfer.fileIndex,
            fileIndex < transfer.files.count,
            !data.isEmpty,
            data.count <= Self.chunkBytes,
            transfer.bytesWrittenOfCurrentFile + Int64(data.count) <= transfer.files[fileIndex].size
        else {
            abortIncoming(transfer, notifyPeer: true, failure: "protocol error")
            return
        }

        do {
            if transfer.handle == nil {
                try openNextFile(for: transfer)
            }
            try transfer.handle?.write(contentsOf: data)
        } catch {
            abortIncoming(transfer, notifyPeer: true, failure: error.localizedDescription)
            return
        }

        transfer.hasher.update(data: data)
        transfer.bytesWrittenOfCurrentFile += Int64(data.count)
        transfer.totalBytesWritten += Int64(data.count)
        transfer.expectedChunkIndex += 1
        transfer.lastActivity = Date()
        send(kind: "ack", transferId: transfer.transferId, target: transfer.origin, chunkIndex: chunkIndex)
        reportReceiveProgress(transfer)
    }

    private func handleFileDone(_ message: FileTransferMessage) {
        guard let transfer = incoming[message.transferId], transfer.origin == message.origin else {
            return
        }
        guard
            let fileIndex = message.fileIndex,
            fileIndex == transfer.fileIndex,
            fileIndex < transfer.files.count
        else {
            abortIncoming(transfer, notifyPeer: true, failure: "protocol error")
            return
        }

        let file = transfer.files[fileIndex]
        do {
            // A zero-byte file arrives as a bare fileDone with no preceding chunk; materialize it.
            if transfer.handle == nil {
                try openNextFile(for: transfer)
            }
            try transfer.handle?.close()
            transfer.handle = nil
        } catch {
            abortIncoming(transfer, notifyPeer: true, failure: error.localizedDescription)
            return
        }

        let digest = transfer.hasher.finalize()
        guard
            transfer.bytesWrittenOfCurrentFile == file.size,
            let expectedHex = message.sha256,
            Self.hex(digest) == expectedHex.lowercased()
        else {
            abortIncoming(transfer, notifyPeer: true, failure: "checksum mismatch")
            return
        }

        transfer.fileIndex += 1
        transfer.bytesWrittenOfCurrentFile = 0
        transfer.hasher = SHA256()
        transfer.lastActivity = Date()

        if transfer.fileIndex == transfer.files.count {
            incoming.removeValue(forKey: transfer.transferId)
            stopWatchdogIfIdle()
            send(kind: "done", transferId: transfer.transferId, target: transfer.origin)
            onFilesReceived?(transfer.writtenURLs)
        }
    }

    private func handleCancel(_ message: FileTransferMessage) {
        if let transfer = incoming[message.transferId], transfer.origin == message.origin {
            abortIncoming(transfer, notifyPeer: false, failure: message.reason ?? "cancelled by sender")
        }
        if let transfer = outgoing, transfer.transferId == message.transferId {
            finishOutgoing(transfer, failure: message.reason ?? "cancelled by receiver")
        }
    }

    private func openNextFile(for transfer: IncomingTransfer) throws {
        let url = transfer.directory.appendingPathComponent(transfer.files[transfer.fileIndex].name)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw TransferError.cannotCreateFile(transfer.files[transfer.fileIndex].name)
        }
        transfer.handle = try FileHandle(forWritingTo: url)
        transfer.writtenURLs.append(url)
    }

    private func reportReceiveProgress(_ transfer: IncomingTransfer) {
        guard transfer.totalBytes > 0 else {
            return
        }
        let percent = Int(transfer.totalBytesWritten * 100 / transfer.totalBytes)
        guard percent != transfer.lastReportedPercent else {
            return
        }
        transfer.lastReportedPercent = percent
        onStatus?(AppText.format("status.fileReceiveProgress", percent))
    }

    private func abortIncoming(_ transfer: IncomingTransfer, notifyPeer: Bool, failure: String?) {
        guard incoming.removeValue(forKey: transfer.transferId) != nil else {
            return
        }
        try? transfer.handle?.close()
        transfer.handle = nil
        try? FileManager.default.removeItem(at: transfer.directory)
        if notifyPeer {
            send(kind: "cancel", transferId: transfer.transferId, target: transfer.origin, reason: failure)
        }
        if let failure {
            onStatus?(AppText.format("status.fileTransferFailed", failure))
        }
        stopWatchdogIfIdle()
    }

    // MARK: - Watchdog

    /// Transfers ride the same silent-drop transport as everything else, so a vanished peer (or a
    /// peer that never understood the offer) must be detected by inactivity rather than an error.
    private func startWatchdogIfNeeded() {
        guard watchdog == nil else {
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            self?.checkTimeouts()
        }
        watchdog = timer
        timer.resume()
    }

    private func stopWatchdogIfIdle() {
        guard outgoing == nil, incoming.isEmpty else {
            return
        }
        watchdog?.cancel()
        watchdog = nil
    }

    private func checkTimeouts() {
        let cutoff = Date().addingTimeInterval(-Self.inactivityTimeout)
        if let transfer = outgoing, transfer.lastActivity < cutoff {
            send(kind: "cancel", transferId: transfer.transferId, target: transfer.target, reason: "timed out")
            finishOutgoing(transfer, failure: "timed out")
        }
        for transfer in Array(incoming.values) where transfer.lastActivity < cutoff {
            abortIncoming(transfer, notifyPeer: true, failure: "timed out")
        }
    }

    // MARK: - Helpers

    private enum TransferError: Error {
        case fileChanged(String)
        case cannotCreateFile(String)

        var reason: String {
            switch self {
            case .fileChanged(let name):
                return "file changed while sending: \(name)"
            case .cannotCreateFile(let name):
                return "cannot create file: \(name)"
            }
        }
    }

    private func send(
        kind: String,
        transferId: String,
        target: String,
        files: [FileTransferFileInfo]? = nil,
        fileIndex: Int? = nil,
        chunkIndex: Int? = nil,
        dataBase64: String? = nil,
        sha256: String? = nil,
        reason: String? = nil
    ) {
        onSend?(FileTransferMessage(
            type: "file",
            origin: deviceId,
            target: target,
            kind: kind,
            transferId: transferId,
            files: files,
            fileIndex: fileIndex,
            chunkIndex: chunkIndex,
            dataBase64: dataBase64,
            sha256: sha256,
            reason: reason,
            sentAt: Date().timeIntervalSince1970
        ))
    }

    private static func hex(_ digest: SHA256Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func safeFileName(_ name: String, fallback: String) -> String {
        let lastComponent = (name as NSString).lastPathComponent
        let filtered = lastComponent.map { character in
            character == "/" || character == ":" ? "_" : character
        }
        let result = String(filtered).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty || result == "." || result == ".." ? fallback : result
    }
}
