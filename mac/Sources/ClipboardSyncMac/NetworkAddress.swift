import Foundation

enum NetworkAddress {
    static func localLANIPv4Address() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let firstInterface = interfaces else {
            return nil
        }
        defer {
            freeifaddrs(interfaces)
        }

        var fallbackAddress: String?
        var pointer: UnsafeMutablePointer<ifaddrs>? = firstInterface

        while let interface = pointer {
            defer {
                pointer = interface.pointee.ifa_next
            }

            let flags = Int32(interface.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else {
                continue
            }

            guard
                let address = interface.pointee.ifa_addr,
                address.pointee.sa_family == UInt8(AF_INET)
            else {
                continue
            }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                address,
                socklen_t(address.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else {
                continue
            }

            let ipAddress = String(cString: host)
            guard !ipAddress.hasPrefix("169.254.") else {
                continue
            }

            let interfaceName = String(cString: interface.pointee.ifa_name)
            if interfaceName.hasPrefix("en") {
                return ipAddress
            }

            fallbackAddress = fallbackAddress ?? ipAddress
        }

        return fallbackAddress
    }

    static func hostAddress() -> String {
        localLANIPv4Address() ?? Host.current().name ?? "this-mac.local"
    }

    static func serverURL(port: Int) -> String {
        "ws://\(hostAddress()):\(port)/"
    }

    static func serverAddress(port: Int) -> String {
        "\(hostAddress()):\(port)"
    }

    static func isLoopbackHost(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "localhost" ||
            normalized == "::1" ||
            normalized.hasPrefix("127.")
    }
}
