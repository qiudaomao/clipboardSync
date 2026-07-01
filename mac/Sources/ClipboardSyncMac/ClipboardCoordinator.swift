import AppKit

final class ClipboardCoordinator {
    var onLocalContent: ((ClipboardContent) -> Void)?
    var onLocalSkipped: ((String) -> Void)?

    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var lastSignature: String?

    func start() {
        lastChangeCount = NSPasteboard.general.changeCount
        lastSignature = readContent(from: NSPasteboard.general)?.signature
        timer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func readFilesForManualSend() -> ClipboardContent? {
        readFileContent(from: NSPasteboard.general)
    }

    @discardableResult
    func applyContent(_ content: ClipboardContent) -> Bool {
        guard content.signature != lastSignature else {
            return true
        }

        guard write(content, to: NSPasteboard.general) else {
            return false
        }

        lastSignature = content.signature
        lastChangeCount = NSPasteboard.general.changeCount
        return true
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else {
            return
        }

        lastChangeCount = pasteboard.changeCount
        guard let content = readContent(from: pasteboard), content.signature != lastSignature else {
            return
        }

        lastSignature = content.signature
        onLocalContent?(content)
    }

    private func readContent(from pasteboard: NSPasteboard) -> ClipboardContent? {
        if hasFileURLs(in: pasteboard) {
            return nil
        }

        if let imageContent = readImageContent(from: pasteboard) {
            return imageContent
        }

        if let text = pasteboard.string(forType: .string) {
            return .text(text)
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

    private func readFileContent(from pasteboard: NSPasteboard) -> ClipboardContent? {
        guard
            let urls = pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [NSURL],
            !urls.isEmpty
        else {
            return nil
        }

        var files: [ClipboardFilePayload] = []
        for nsURL in urls {
            let url = nsURL as URL
            guard url.isFileURL else {
                continue
            }

            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else {
                onLocalSkipped?(AppText.text("status.folderUnsupported"))
                return nil
            }

            let size = values?.fileSize ?? 0
            guard size <= ClipboardLimits.maxFileBytes else {
                onLocalSkipped?(AppText.text("status.fileTooLarge"))
                return nil
            }

            guard let data = try? Data(contentsOf: url), data.count <= ClipboardLimits.maxFileBytes else {
                onLocalSkipped?(AppText.text("status.fileTooLarge"))
                return nil
            }

            files.append(ClipboardFilePayload(
                name: Self.safeFileName(url.lastPathComponent, fallback: "clipboard-file"),
                dataBase64: data.base64EncodedString(),
                size: data.count
            ))
        }

        return files.isEmpty ? nil : .files(files)
    }

    private func readImageContent(from pasteboard: NSPasteboard) -> ClipboardContent? {
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

        return .image(ClipboardImagePayload(
            mimeType: "image/png",
            fileName: "clipboard.png",
            dataBase64: data.base64EncodedString(),
            size: data.count
        ))
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
