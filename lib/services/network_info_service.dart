import 'dart:io';

import 'package:network_info_plus/network_info_plus.dart';

import '../models/network_snapshot.dart';

/// Reads Android/Wi-Fi addressing information without doing any communication.
///
/// This service has one narrow responsibility: describe the current LAN. The
/// discovery and audio services consume that data, but do not ask Android for
/// it themselves. That separation makes network transport easier to reason
/// about and makes this service replaceable in tests.
class NetworkInfoService {
  NetworkInfoService({NetworkInfo? networkInfo})
      : _networkInfo = networkInfo ?? NetworkInfo();

  final NetworkInfo _networkInfo;

  /// Asks the plugin and Dart runtime for current network metadata.
  ///
  /// Several Wi-Fi values may legally be `null`: Android protects SSID/BSSID
  /// and some devices report incomplete hotspot details. PeerTalk therefore
  /// treats metadata as diagnostic information and falls back to Dart's list
  /// of active IPv4 interfaces when deciding what IP to show.
  Future<NetworkSnapshot> load() async {
    final wifiName = _cleanWifiName(await _safe(_networkInfo.getWifiName()));
    final wifiBssid = await _safe(_networkInfo.getWifiBSSID());
    final wifiIp = await _safe(_networkInfo.getWifiIP());
    final wifiIpv6 = await _safe(_networkInfo.getWifiIPv6());
    final subnetMask = await _safe(_networkInfo.getWifiSubmask());
    final gatewayIp = await _safe(_networkInfo.getWifiGatewayIP());
    final packageBroadcast = await _safe(_networkInfo.getWifiBroadcast());
    final interfaceAddresses = await _interfaceIpv4Addresses();

    return NetworkSnapshot(
      wifiName: wifiName,
      wifiBssid: wifiBssid,
      wifiIp: wifiIp,
      wifiIpv6: wifiIpv6,
      subnetMask: subnetMask,
      gatewayIp: gatewayIp,
      broadcastAddress:
          packageBroadcast ?? _calculateBroadcastAddress(wifiIp, subnetMask),
      interfaceAddresses: interfaceAddresses,
    );
  }

  /// A missing diagnostic field should not prevent push-to-talk from starting.
  /// This wrapper changes a platform exception into a nullable field.
  Future<T?> _safe<T>(Future<T?> future) async {
    try {
      return await future;
    } catch (_) {
      return null;
    }
  }

  /// A network interface is a device/software connection such as Wi-Fi.
  ///
  /// Loopback (`127.0.0.1`) always means "this same phone" and cannot reach a
  /// second phone, so it is deliberately excluded from the available LAN IPs.
  Future<List<String>> _interfaceIpv4Addresses() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLinkLocal: false,
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      return interfaces
          .expand((interface) => interface.addresses)
          .map((address) => address.address)
          .where((address) => !address.startsWith('127.'))
          .toSet()
          .toList(growable: false);
    } catch (_) {
      return const <String>[];
    }
  }

  /// Android APIs sometimes return SSIDs wrapped in quotes for historic API
  /// compatibility. Removing them makes the label readable in our UI.
  String? _cleanWifiName(String? value) {
    if (value == null || value.isEmpty) {
      return value;
    }
    return value.replaceAll('"', '');
  }

  /// Computes the directed broadcast address from IPv4 + subnet mask.
  ///
  /// For each byte, `(ip OR NOT mask)` leaves the network portion untouched
  /// and fills the host portion with ones. Example:
  /// `192.168.1.40` with `255.255.255.0` becomes `192.168.1.255`.
  /// A datagram sent there can be seen by devices on that local subnet.
  String? _calculateBroadcastAddress(String? ip, String? subnetMask) {
    final ipParts = _parseIpv4(ip);
    final maskParts = _parseIpv4(subnetMask);
    if (ipParts == null || maskParts == null) {
      return null;
    }

    final broadcast = <int>[];
    for (var i = 0; i < 4; i += 1) {
      broadcast.add(ipParts[i] | (~maskParts[i] & 0xff));
    }
    return broadcast.join('.');
  }

  /// Validates dotted-decimal IPv4 text and returns its four numeric octets.
  List<int>? _parseIpv4(String? value) {
    if (value == null) {
      return null;
    }
    final parts = value.split('.');
    if (parts.length != 4) {
      return null;
    }

    final parsed = <int>[];
    for (final part in parts) {
      final number = int.tryParse(part);
      if (number == null || number < 0 || number > 255) {
        return null;
      }
      parsed.add(number);
    }
    return parsed;
  }
}
