using System;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;

namespace ClipboardSyncWin;

internal static class NetworkAddress
{
    public static string HostAddress()
    {
        return LocalLanIPv4Address() ?? Dns.GetHostName();
    }

    public static string ServerAddress(int port)
    {
        return $"{HostAddress()}:{port}";
    }

    public static bool IsLoopbackHost(string? host)
    {
        var normalized = host?.Trim().ToLowerInvariant() ?? "";
        if (normalized is "localhost" or "::1")
        {
            return true;
        }

        return IPAddress.TryParse(normalized, out var address)
            ? IPAddress.IsLoopback(address)
            : normalized.StartsWith("127.", StringComparison.Ordinal);
    }

    public static string? LocalLanIPv4Address()
    {
        var interfaces = NetworkInterface.GetAllNetworkInterfaces()
            .Where(item =>
                item.OperationalStatus == OperationalStatus.Up &&
                item.NetworkInterfaceType != NetworkInterfaceType.Loopback &&
                item.NetworkInterfaceType != NetworkInterfaceType.Tunnel)
            .ToArray();

        return FindAddress(interfaces, preferPhysical: true) ??
            FindAddress(interfaces, preferPhysical: false);
    }

    private static string? FindAddress(NetworkInterface[] interfaces, bool preferPhysical)
    {
        foreach (var networkInterface in interfaces)
        {
            if (preferPhysical &&
                networkInterface.NetworkInterfaceType is not NetworkInterfaceType.Ethernet and not NetworkInterfaceType.Wireless80211)
            {
                continue;
            }

            var address = networkInterface.GetIPProperties()
                .UnicastAddresses
                .Select(item => item.Address)
                .FirstOrDefault(address =>
                    address.AddressFamily == AddressFamily.InterNetwork &&
                    !IPAddress.IsLoopback(address) &&
                    !address.ToString().StartsWith("169.254.", StringComparison.Ordinal));

            if (address is not null)
            {
                return address.ToString();
            }
        }

        return null;
    }
}
