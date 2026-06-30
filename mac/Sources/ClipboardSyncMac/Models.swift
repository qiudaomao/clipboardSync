import Foundation

enum SyncMode: String, Codable {
    case client
    case server
}

struct AppConfig: Codable {
    var mode: SyncMode
    var host: String
    var port: Int

    static let defaults = AppConfig(mode: .client, host: "127.0.0.1", port: 8787)
    private static let storageKey = "ClipboardSyncMac.config"

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
            host: host.isEmpty ? Self.defaults.host : host,
            port: min(max(port, 1), 65_535)
        )
    }
}

struct SyncMessage: Codable {
    let type: String
    let origin: String
    let text: String
    let sentAt: TimeInterval
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
