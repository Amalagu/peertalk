/// A read-only snapshot of LAN information visible to the application.
///
/// The app only needs a *local* network. A phone connected to a hotspot can
/// receive an address such as `192.168.43.12` even when that hotspot has no
/// mobile-data or internet connection at all.
class NetworkSnapshot {
  const NetworkSnapshot({
    this.wifiName,
    this.wifiBssid,
    this.wifiIp,
    this.wifiIpv6,
    this.subnetMask,
    this.gatewayIp,
    this.broadcastAddress,
    this.interfaceAddresses = const <String>[],
  });

  /// The Wi-Fi network name (SSID), if Android permission policy exposes it.
  final String? wifiName;

  /// Identifier for the Wi-Fi access point (BSSID), commonly its radio MAC.
  final String? wifiBssid;

  /// The IPv4 address allocated to this phone on the current Wi-Fi LAN.
  final String? wifiIp;

  /// IPv6 equivalent; shown for diagnosis, while version 1 sends over IPv4.
  final String? wifiIpv6;

  /// Identifies which portion of an IPv4 address names the local network.
  /// For example `255.255.255.0` usually places `192.168.1.x` together.
  final String? subnetMask;

  /// The router or hotspot address used to reach networks outside this LAN.
  /// PeerTalk does not need internet routing, but this helps diagnose setup.
  final String? gatewayIp;

  /// IPv4 address whose packets should be delivered to every LAN participant.
  /// Discovery uses it before a specific peer address is known.
  final String? broadcastAddress;

  /// Fallback IPv4 addresses from Dart when the Wi-Fi plugin cannot expose IP
  /// information due to device behavior or Android privacy permissions.
  final List<String> interfaceAddresses;

  /// Prefer the Wi-Fi plugin's IP, otherwise use a Dart network-interface IP.
  String? get primaryIp {
    if (wifiIp != null && wifiIp!.isNotEmpty) {
      return wifiIp;
    }
    if (interfaceAddresses.isNotEmpty) {
      return interfaceAddresses.first;
    }
    return null;
  }

  bool get hasUsableIp => primaryIp != null;

  /// Keeps UI-specific labels in one place while the service owns retrieval.
  List<(String, String)> get displayRows => <(String, String)>[
        ('Local IP', primaryIp ?? 'Unknown'),
        ('Wi-Fi', wifiName ?? 'Unknown'),
        ('BSSID', wifiBssid ?? 'Unknown'),
        ('Gateway', gatewayIp ?? 'Unknown'),
        ('Subnet', subnetMask ?? 'Unknown'),
        ('Broadcast', broadcastAddress ?? '255.255.255.255'),
        ('IPv6', wifiIpv6 ?? 'Unknown'),
      ];
}
