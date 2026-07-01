import Foundation

enum ClipboardLimits {
    static let maxFileBytes = 10 * 1024 * 1024
    static let maxWebSocketMessageBytes = 16 * 1024 * 1024
    static let historyLimit = 10
}

enum SyncMode: String, Codable {
    case client
    case server
}

struct AppConfig: Codable {
    var mode: SyncMode
    var host: String
    var port: Int
    var password: String

    static let defaults = AppConfig(mode: .client, host: "", port: 8787, password: "")
    private static let storageKey = "ClipboardSyncMac.config"

    init(mode: SyncMode, host: String, port: Int, password: String) {
        self.mode = mode
        self.host = host
        self.port = port
        self.password = password
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decodeIfPresent(SyncMode.self, forKey: .mode) ?? Self.defaults.mode
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? Self.defaults.host
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? Self.defaults.port
        password = try container.decodeIfPresent(String.self, forKey: .password) ?? Self.defaults.password
    }

    static func load() -> AppConfig {
        guard
            let data = UserDefaults.standard.data(forKey: storageKey),
            let config = try? JSONDecoder().decode(AppConfig.self, from: data)
        else {
            return defaults
        }
        return config.normalized()
    }

    func save() {
        if let data = try? JSONEncoder().encode(normalized()) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    private func normalized() -> AppConfig {
        AppConfig(
            mode: mode,
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: min(max(port, 1), 65_535),
            password: password
        )
    }
}

struct EncryptedEnvelope: Codable {
    let type: String
    let version: Int
    let salt: String
    let nonce: String
    let ciphertext: String
    let tag: String
}

struct SyncMessage: Codable {
    let type: String
    let origin: String
    let kind: String?
    let text: String?
    let image: ClipboardImagePayload?
    let files: [ClipboardFilePayload]?
    let sentAt: TimeInterval
}

struct ClipboardImagePayload: Codable, Equatable {
    let mimeType: String
    let fileName: String
    let dataBase64: String
    let size: Int
}

struct ClipboardFilePayload: Codable, Equatable {
    let name: String
    let dataBase64: String
    let size: Int
}

enum ClipboardContent: Equatable {
    case text(String)
    case image(ClipboardImagePayload)
    case files([ClipboardFilePayload])

    var kind: String {
        switch self {
        case .text:
            return "text"
        case .image:
            return "image"
        case .files:
            return "files"
        }
    }

    var signature: String {
        switch self {
        case .text(let text):
            return "text:\(text)"
        case .image(let image):
            return "image:\(image.dataBase64)"
        case .files(let files):
            return "files:\(files.map { "\($0.name):\($0.size):\($0.dataBase64)" }.joined(separator: "|"))"
        }
    }

    var historyTitle: String {
        switch self {
        case .text(let text):
            let compact = text.replacingOccurrences(of: "\n", with: " ")
            let preview = String(compact.prefix(42))
            return preview.isEmpty ? "Text" : "Text: \(preview)"
        case .image(let image):
            return "Image: \(ByteCountFormatter.string(fromByteCount: Int64(image.size), countStyle: .file))"
        case .files(let files):
            let names = files.prefix(2).map(\.name).joined(separator: ", ")
            let suffix = files.count > 2 ? " +\(files.count - 2)" : ""
            return "Files: \(names)\(suffix)"
        }
    }

    func makeMessage(origin: String) -> SyncMessage {
        switch self {
        case .text(let text):
            return SyncMessage(
                type: "clipboard",
                origin: origin,
                kind: kind,
                text: text,
                image: nil,
                files: nil,
                sentAt: Date().timeIntervalSince1970
            )
        case .image(let image):
            return SyncMessage(
                type: "clipboard",
                origin: origin,
                kind: kind,
                text: nil,
                image: image,
                files: nil,
                sentAt: Date().timeIntervalSince1970
            )
        case .files(let files):
            return SyncMessage(
                type: "clipboard",
                origin: origin,
                kind: kind,
                text: nil,
                image: nil,
                files: files,
                sentAt: Date().timeIntervalSince1970
            )
        }
    }
}

extension SyncMessage {
    func clipboardContent() -> ClipboardContent? {
        let resolvedKind = kind ?? (text == nil ? nil : "text")
        switch resolvedKind {
        case "text":
            guard let text else {
                return nil
            }
            return .text(text)
        case "image":
            guard let image else {
                return nil
            }
            return .image(image)
        case "files":
            guard let files, !files.isEmpty else {
                return nil
            }
            return .files(files)
        default:
            return nil
        }
    }
}

struct ClipboardHistoryEntry {
    let id: UUID
    let content: ClipboardContent
    let createdAt: Date
}

enum DeviceIdentity {
    private static let storageKey = "ClipboardSyncMac.deviceId"

    static var current: String {
        if let existing = UserDefaults.standard.string(forKey: storageKey) {
            return existing
        }
        let created = UUID().uuidString
        UserDefaults.standard.set(created, forKey: storageKey)
        return created
    }
}
