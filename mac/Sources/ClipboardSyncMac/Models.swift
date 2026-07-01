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

enum ScreenEdge: String, Codable, CaseIterable {
    case left
    case right
    case top
    case bottom

    var title: String {
        rawValue.prefix(1).uppercased() + rawValue.dropFirst()
    }

    var opposite: ScreenEdge {
        switch self {
        case .left:
            return .right
        case .right:
            return .left
        case .top:
            return .bottom
        case .bottom:
            return .top
        }
    }
}

struct AppConfig: Codable {
    var mode: SyncMode
    var host: String
    var port: Int
    var password: String
    var inputSharingEnabled: Bool
    var controlDeviceId: String?
    var peerEdge: ScreenEdge

    static let defaults = AppConfig(
        mode: .client,
        host: "",
        port: 8787,
        password: "",
        inputSharingEnabled: false,
        controlDeviceId: nil,
        peerEdge: .right
    )
    private static let storageKey = "ClipboardSyncMac.config"

    init(
        mode: SyncMode,
        host: String,
        port: Int,
        password: String,
        inputSharingEnabled: Bool,
        controlDeviceId: String?,
        peerEdge: ScreenEdge
    ) {
        self.mode = mode
        self.host = host
        self.port = port
        self.password = password
        self.inputSharingEnabled = inputSharingEnabled
        self.controlDeviceId = controlDeviceId
        self.peerEdge = peerEdge
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decodeIfPresent(SyncMode.self, forKey: .mode) ?? Self.defaults.mode
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? Self.defaults.host
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? Self.defaults.port
        password = try container.decodeIfPresent(String.self, forKey: .password) ?? Self.defaults.password
        inputSharingEnabled = try container.decodeIfPresent(Bool.self, forKey: .inputSharingEnabled) ?? Self.defaults.inputSharingEnabled
        controlDeviceId = try container.decodeIfPresent(String.self, forKey: .controlDeviceId) ?? Self.defaults.controlDeviceId
        peerEdge = try container.decodeIfPresent(ScreenEdge.self, forKey: .peerEdge) ?? Self.defaults.peerEdge
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
            password: password,
            inputSharingEnabled: inputSharingEnabled,
            controlDeviceId: controlDeviceId?.trimmingCharacters(in: .whitespacesAndNewlines),
            peerEdge: peerEdge
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

struct MessageHeader: Codable {
    let type: String
    let origin: String?
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

struct InputMessage: Codable {
    let type: String
    let origin: String
    let target: String?
    let kind: String
    let role: String?
    let deviceName: String?
    let deviceAddress: String?
    let screen: ScreenMetrics?
    let enabled: Bool?
    let controlDeviceId: String?
    let peerEdge: String?
    let capture: InputCapturePayload?
    let mouse: InputMousePayload?
    let key: InputKeyPayload?
    let sentAt: TimeInterval

    static func hello(
        origin: String,
        role: SyncMode,
        deviceName: String,
        deviceAddress: String?,
        screen: ScreenMetrics,
        enabled: Bool,
        controlDeviceId: String?,
        peerEdge: ScreenEdge
    ) -> InputMessage {
        InputMessage(
            type: "input",
            origin: origin,
            target: nil,
            kind: "hello",
            role: role.rawValue,
            deviceName: deviceName,
            deviceAddress: deviceAddress,
            screen: screen,
            enabled: enabled,
            controlDeviceId: controlDeviceId,
            peerEdge: peerEdge.rawValue,
            capture: nil,
            mouse: nil,
            key: nil,
            sentAt: Date().timeIntervalSince1970
        )
    }
}

struct ScreenMetrics: Codable {
    let width: Double
    let height: Double
    let scale: Double
}

struct InputCapturePayload: Codable {
    let action: String
    let edge: String
    let normalizedX: Double
    let normalizedY: Double
}

struct InputMousePayload: Codable {
    let action: String
    let button: String?
    let normalizedX: Double?
    let normalizedY: Double?
    let deltaX: Double?
    let deltaY: Double?
}

struct InputKeyPayload: Codable {
    let action: String
    let key: String
    let modifiers: [String]
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

    static var displayName: String {
        Host.current().localizedName ?? Host.current().name ?? ProcessInfo.processInfo.hostName
    }

    static var address: String? {
        NetworkAddress.localLANIPv4Address()
    }
}
