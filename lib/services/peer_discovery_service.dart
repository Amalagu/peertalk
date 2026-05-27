import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:udp/udp.dart';

import '../models/communication_mode.dart';
import '../models/network_snapshot.dart';
import '../models/peer.dart';
import 'app_constants.dart';
import 'debug_log_service.dart';

/// Announces this device and receives peer announcements over UDP broadcast.
///
/// Discovery is separate from call signaling. A visible peer is simply online
/// enough to have recently advertised itself; pressing Call begins a session.
class PeerDiscoveryService {
  PeerDiscoveryService({required DebugLogService logs}) : _logs = logs;

  final DebugLogService _logs;

  /// UDP socket bound to the well-known discovery port on this phone.
  ///
  /// Binding means Android will deliver datagrams addressed to that port to
  /// this app while it is open in the foreground.
  UDP? _socket;
  StreamSubscription<Datagram?>? _subscription;

  /// Repeated announcements replace the need for a central directory server.
  Timer? _broadcastTimer;
  String? _deviceId;
  String? _deviceName;
  NetworkSnapshot? _network;
  final Set<CommunicationMode> _supportedModes = const <CommunicationMode>{
    CommunicationMode.pushToTalk,
    CommunicationMode.fullDuplex,
  };

  /// Controller callback used after networking has converted JSON into a Peer.
  void Function(Peer peer)? _onPeerFound;

  /// Opens discovery listening and immediately announces this device.
  ///
  /// All devices bind the same UDP port because each is both discoverer and
  /// discoverable. A phone may send a broadcast before another app instance is
  /// listening, so periodic retransmission is essential.
  Future<void> start({
    required String deviceId,
    required String deviceName,
    required NetworkSnapshot network,
    required int intervalSeconds,
    required void Function(Peer peer) onPeerFound,
  }) async {
    await stop();
    _deviceId = deviceId;
    _deviceName = deviceName;
    _network = network;
    _onPeerFound = onPeerFound;
    try {
      _socket = await UDP.bind(Endpoint.any(port: const Port(discoveryPort)));
      // UDP broadcasts are disabled by default on many socket APIs to prevent
      // accidental LAN-wide traffic. Peer discovery explicitly opts into it.
      _socket?.socket?.broadcastEnabled = true;
      _subscription = _socket
          ?.asStream()
          .listen(_handleDatagram, onError: _handleListenError);
      _logs.info('Discovery listening on UDP $discoveryPort');
      await broadcastPresence();
      _broadcastTimer = Timer.periodic(
        Duration(seconds: intervalSeconds),
        (_) => unawaited(broadcastPresence()),
      );
    } catch (error) {
      _logs.error('Unable to bind discovery port $discoveryPort: $error');
      rethrow;
    }
  }

  /// Sends both the broad and subnet-derived form because hotspot firmware
  /// varies in which broadcast address it forwards to attached devices.
  Future<void> broadcastPresence() async {
    final socket = _socket;
    if (socket == null || socket.closed) {
      return;
    }
    final bytes = utf8.encode(jsonEncode(_payload(discoveryHello)));
    await _send(
        socket, bytes, Endpoint.broadcast(port: const Port(discoveryPort)));
    final directedBroadcast = _network?.broadcastAddress;
    if (directedBroadcast != null && directedBroadcast != '255.255.255.255') {
      await _send(
        socket,
        bytes,
        Endpoint.unicast(
          InternetAddress(directedBroadcast),
          port: const Port(discoveryPort),
        ),
      );
    }
  }

  /// Closes timers and socket ownership when discovery is restarted/disposed.
  Future<void> stop() async {
    _broadcastTimer?.cancel();
    _broadcastTimer = null;
    await _subscription?.cancel();
    _subscription = null;
    _socket?.close();
    _socket = null;
  }

  /// Sends one discovery JSON datagram and changes network errors into logs.
  ///
  /// Missing one presence broadcast is normal; the next periodic packet may
  /// succeed after a brief Wi-Fi transition.
  Future<void> _send(UDP socket, List<int> bytes, Endpoint endpoint) async {
    try {
      await socket.send(bytes, endpoint);
    } catch (error) {
      _logs.warning('Discovery send failed: $error');
    }
  }

  /// Parses discovery traffic arriving from any phone on this broadcast LAN.
  void _handleDatagram(Datagram? datagram) {
    if (datagram == null) {
      return;
    }
    try {
      final message =
          jsonDecode(utf8.decode(datagram.data)) as Map<String, Object?>;
      if (message['app'] != appProtocolName ||
          message['version'] != appProtocolVersion ||
          message['deviceId'] == _deviceId) {
        // Ignore unrelated applications/versions and our own broadcast looped
        // back by Android. A phone should not appear as its own peer.
        return;
      }
      final deviceId = message['deviceId'] as String?;
      if (deviceId == null) {
        return;
      }
      final modes = (message['supportedModes'] as List<Object?>? ??
              const <Object?>['push_to_talk'])
          .whereType<String>()
          .map(CommunicationModeDisplay.fromWireName)
          .toSet();
      // Normally the sender's advertised Wi-Fi IP and the socket source IP are
      // equal. Falling back to socket metadata keeps discovery usable on
      // Android builds where local-network details are not exposed.
      final advertisedIp = (message['ip'] as String?)?.trim();
      final peer = Peer(
        id: deviceId,
        name: (message['name'] as String?)?.trim().isNotEmpty == true
            ? (message['name'] as String).trim()
            : 'Peer ${datagram.address.address}',
        ipAddress: advertisedIp?.isNotEmpty == true
            ? advertisedIp!
            : datagram.address.address,
        audioPort: _readPort(message['audioPort'], audioPort),
        controlPort: _readPort(message['controlPort'], controlPort),
        discoveryPort: _readPort(message['discoveryPort'], discoveryPort),
        lastSeen: DateTime.now(),
        supportedModes: modes,
      );
      _onPeerFound?.call(peer);
      if (message['type'] == discoveryHello) {
        // A direct reply speeds appearance in the sender's list. Periodic
        // broadcast remains the long-term source of last-seen refreshes.
        unawaited(_reply(datagram.address, peer.discoveryPort));
      }
    } catch (_) {
      // Other UDP payloads on this LAN are not discovery packets.
    }
  }

  /// Answers one hello directly to the requesting address rather than all LAN
  /// devices, since only that requester needs the immediate response.
  Future<void> _reply(InternetAddress address, int port) async {
    final socket = _socket;
    if (socket == null || socket.closed) {
      return;
    }
    await _send(
      socket,
      utf8.encode(jsonEncode(_payload(discoveryHere))),
      Endpoint.unicast(address, port: Port(port)),
    );
  }

  /// Creates the capability advertisement understood by another V2 phone.
  ///
  /// It contains addresses and features, not credentials or account data.
  Map<String, Object?> _payload(String type) => <String, Object?>{
        'app': appProtocolName,
        'version': appProtocolVersion,
        'type': type,
        'deviceId': _deviceId,
        'name': _deviceName,
        'ip': _network?.primaryIp,
        'audioPort': audioPort,
        'controlPort': controlPort,
        'discoveryPort': discoveryPort,
        'supportedModes': _supportedModes.map((mode) => mode.wireName).toList(),
        'sentAt': DateTime.now().toUtc().toIso8601String(),
      };

  /// Tolerates JSON numbers or numeric text from future/other implementations.
  int _readPort(Object? value, int fallback) =>
      value is int ? value : int.tryParse('$value') ?? fallback;

  void _handleListenError(Object error) {
    _logs.error('Discovery listener error: $error');
  }
}
