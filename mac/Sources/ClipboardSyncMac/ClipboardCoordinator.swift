import AppKit
#if SWIFT_PACKAGE
import ClipboardSyncCore
#endif

final class ClipboardCoordinator {
    var onLocalContent: ((ClipboardContent, String) -> Void)?
    var onLocalSkipped: ((String) -> Void)?

    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var lastSignature: String?
    private var imageChangeTraceTimer: Timer?
    private var tracedChangeCount = NSPasteboard.general.changeCount
    private var lastTracedChangeUptime: TimeInterval?
    private var imageChangeTraceDeadlineUptime: TimeInterval = 0

    private static let imageChangeTraceInterval: TimeInterval = 0.01
    private static let imageChangeTraceDuration: TimeInterval = 3

    private struct Observation {
        let content: ClipboardContent
        let signature: String
    }

    func start() {
        lastChangeCount = NSPasteboard.general.changeCount
        lastSignature = readObservation(from: NSPasteboard.general)?.signature
        timer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        stopImageChangeTrace()
    }

    /// The file URLs currently on the clipboard, for a chunked transfer. Only regular files are
    /// supported; folders surface a skip status and return nil. Size is deliberately not checked —
    /// transfers stream disk-to-disk.
    func readFileURLsForManualSend() -> [URL]? {
        guard
            let urls = NSPasteboard.general.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [NSURL],
            !urls.isEmpty
        else {
            return nil
        }

        var fileURLs: [URL] = []
        for nsURL in urls {
            let url = nsURL as URL
            guard url.isFileURL else {
                continue
            }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else {
                onLocalSkipped?(AppText.text("status.folderUnsupported"))
                return nil
            }
            fileURLs.append(url)
        }
        return fileURLs.isEmpty ? nil : fileURLs
    }

    /// Names of the files currently on the clipboard, for menu display only. Mirrors
    /// `readFileURLsForManualSend` (nil for folders or an empty clipboard) but never surfaces a
    /// skip status.
    func peekFileNamesForManualSend() -> [String]? {
        guard
            let urls = NSPasteboard.general.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [NSURL],
            !urls.isEmpty
        else {
            return nil
        }

        var names: [String] = []
        for nsURL in urls {
            let url = nsURL as URL
            guard url.isFileURL else {
                continue
            }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else {
                return nil
            }
            names.append(url.lastPathComponent)
        }
        return names.isEmpty ? nil : names
    }

    /// Puts files a completed transfer already wrote to disk onto the clipboard as file-drop URLs.
    @discardableResult
    func applyReceivedFileURLs(_ urls: [URL]) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let written = pasteboard.writeObjects(urls as [NSURL])
        lastChangeCount = pasteboard.changeCount
        return written
    }

    @discardableResult
    func applyContent(_ content: ClipboardContent, signature providedSignature: String? = nil) -> Bool {
        let signature = providedSignature ?? content.signature
        guard signature != lastSignature else {
            return true
        }

        guard write(content, to: NSPasteboard.general) else {
            return false
        }

        lastSignature = signature
        lastChangeCount = NSPasteboard.general.changeCount
        return true
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else {
            return
        }

        let observedChangeCount = pasteboard.changeCount
        lastChangeCount = observedChangeCount
        guard let observation = readObservation(from: pasteboard) else {
            return
        }

        let content = observation.content
        let signature = observation.signature
        let isDuplicate = signature == lastSignature
        if case .image(let image) = content {
            let types = pasteboard.types?.map(\.rawValue).joined(separator: ",") ?? "none"
            startImageChangeTrace(changeCount: observedChangeCount, types: types)
            NSLog(
                "Clipboard image observation: eventUnixMs=\(Self.unixMilliseconds()) "
                    + "changeCount=\(observedChangeCount) "
                    + "encodedBytes=\(image.size) identity=\(signature) "
                    + "duplicate=\(isDuplicate) types=\(types)"
            )
        }
        guard !isDuplicate else {
            return
        }

        lastSignature = signature
        onLocalContent?(content, signature)
    }

    /// The normal clipboard poll is intentionally low-frequency to avoid idle wakeups. When an
    /// image is observed, briefly sample only `changeCount` at 10 ms resolution so a screenshot
    /// reproduction reveals the actual spacing of the pasteboard ownership changes. No image data
    /// is decoded on this diagnostic timer.
    private func startImageChangeTrace(changeCount: Int, types: String) {
        let now = ProcessInfo.processInfo.systemUptime
        if imageChangeTraceTimer == nil || tracedChangeCount != changeCount {
            recordTracedChange(
                changeCount: changeCount,
                uptime: now,
                source: "initial",
                types: types
            )
        }
        imageChangeTraceDeadlineUptime = now + Self.imageChangeTraceDuration

        guard imageChangeTraceTimer == nil else {
            return
        }

        let traceTimer = Timer(timeInterval: Self.imageChangeTraceInterval, repeats: true) { [weak self] _ in
            self?.sampleImageChangeTrace()
        }
        traceTimer.tolerance = 0.002
        RunLoop.main.add(traceTimer, forMode: .common)
        imageChangeTraceTimer = traceTimer
    }

    private func sampleImageChangeTrace() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now < imageChangeTraceDeadlineUptime else {
            stopImageChangeTrace()
            return
        }

        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        guard changeCount != tracedChangeCount else {
            return
        }

        let types = pasteboard.types?.map(\.rawValue).joined(separator: ",") ?? "none"
        recordTracedChange(
            changeCount: changeCount,
            uptime: now,
            source: "sample",
            types: types
        )
        imageChangeTraceDeadlineUptime = now + Self.imageChangeTraceDuration
    }

    private func recordTracedChange(
        changeCount: Int,
        uptime: TimeInterval,
        source: String,
        types: String
    ) {
        let deltaMilliseconds = lastTracedChangeUptime.map { (uptime - $0) * 1_000 }
        let deltaText = deltaMilliseconds.map { String(format: "%.1f", $0) } ?? "first"
        tracedChangeCount = changeCount
        lastTracedChangeUptime = uptime
        NSLog(
            "Clipboard change trace: eventUnixMs=\(Self.unixMilliseconds()) "
                + "deltaMs=\(deltaText) changeCount=\(changeCount) "
                + "source=\(source) types=\(types)"
        )
    }

    private func stopImageChangeTrace() {
        imageChangeTraceTimer?.invalidate()
        imageChangeTraceTimer = nil
        tracedChangeCount = NSPasteboard.general.changeCount
        lastTracedChangeUptime = nil
        imageChangeTraceDeadlineUptime = 0
    }

    private static func unixMilliseconds() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    }

    private func readObservation(from pasteboard: NSPasteboard) -> Observation? {
        if hasFileURLs(in: pasteboard) {
            return nil
        }

        if let imageObservation = readImageObservation(from: pasteboard) {
            return imageObservation
        }

        if let text = pasteboard.string(forType: .string) {
            let content = ClipboardContent.text(text)
            return Observation(content: content, signature: content.signature)
        }

        return nil
    }

    private func hasFileURLs(in pasteboard: NSPasteboard) -> Bool {
        guard
            let urls = pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [NSURL]
        else {
            return false
        }
        return !urls.isEmpty
    }

    private func readImageObservation(from pasteboard: NSPasteboard) -> Observation? {
        let pngData = pasteboard.data(forType: .png) ?? {
            guard
                let tiffData = pasteboard.data(forType: .tiff),
                let image = NSImage(data: tiffData)
            else {
                return nil
            }
            return Self.pngData(from: image)
        }()

        guard let data = pngData else {
            return nil
        }

        guard data.count <= ClipboardLimits.maxFileBytes else {
            onLocalSkipped?(AppText.text("status.imageTooLarge"))
            return nil
        }

        let content = ClipboardContent.image(ClipboardImagePayload(
            mimeType: "image/png",
            fileName: "clipboard.png",
            dataBase64: data.base64EncodedString(),
            size: data.count
        ))
        let signature = "image:\(ClipboardImageIdentity.signature(for: data))"
        return Observation(content: content, signature: signature)
    }

    private func write(_ content: ClipboardContent, to pasteboard: NSPasteboard) -> Bool {
        switch content {
        case .text(let text):
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            return true
        case .image(let image):
            guard let data = Data(base64Encoded: image.dataBase64), data.count <= ClipboardLimits.maxFileBytes else {
                return false
            }
            pasteboard.clearContents()
            pasteboard.setData(data, forType: .png)
            return true
        case .files(let files):
            guard let urls = writeReceivedFiles(files) else {
                return false
            }
            pasteboard.clearContents()
            return pasteboard.writeObjects(urls)
        }
    }

    private func writeReceivedFiles(_ files: [ClipboardFilePayload]) -> [NSURL]? {
        let fileManager = FileManager.default
        guard let supportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }

        let directory = supportURL
            .appendingPathComponent("ClipboardSync", isDirectory: true)
            .appendingPathComponent("Received", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        var urls: [NSURL] = []
        for (index, file) in files.enumerated() {
            guard
                file.size <= ClipboardLimits.maxFileBytes,
                let data = Data(base64Encoded: file.dataBase64),
                data.count <= ClipboardLimits.maxFileBytes
            else {
                return nil
            }

            let name = Self.safeFileName(file.name, fallback: "clipboard-file-\(index + 1)")
            let destination = directory.appendingPathComponent(name)
            do {
                try data.write(to: destination, options: .atomic)
                urls.append(destination as NSURL)
            } catch {
                return nil
            }
        }

        return urls.isEmpty ? nil : urls
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard
            let tiffData = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiffData)
        else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }

    private static func safeFileName(_ name: String, fallback: String) -> String {
        let lastComponent = (name as NSString).lastPathComponent
        let filtered = lastComponent
            .map { character in
                character == "/" || character == ":" ? "_" : character
            }
        let result = String(filtered).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? fallback : result
    }
}
