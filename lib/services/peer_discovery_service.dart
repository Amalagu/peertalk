import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:udp/udp.dart';

import '../models/network_snapshot.dart';
import '../models/peer.dart';
import 'app_constants.dart';

/// Finds PeerTalk instances without a central server.
///
/// The central idea is UDP broadcast: a phone sends one short announcement to
/// a LAN-wide address before it knows any peer IP. Every running instance that
/// is listening on [discoveryPort] can hear that announcement, store the
/// sender as a [Peer], and send a direct response. Some hotspot/router vendors
/// suppress broadcast traffic, which is why the app also supports manual IP.
class PeerDiscoveryService {
  /// The bound UDP socket receives announcements and sends responses.
  UDP? _socket;

  /// A Dart stream subscription converts incoming datagrams into callbacks.
  StreamSubscription<Datagram?>? _subscription;

  /// Periodic broadcasts allow phones that open the app later to be discovered.
  Timer? _broadcastTimer;

  String? _deviceId;
  String? _deviceName;
  NetworkSnapshot? _network;
  void Function(Peer peer)? _onPeerFound;
  void Function(String message)? _onLog;

  /// Opens the discovery socket and begins advertising this phone.
  ///
  /// A UDP socket is "connectionless": binding claims a local listening port,
  /// but there is no call setup or permanent connection to another phone.
  Future<void> start({
    required String deviceId,
    required String deviceName,
    required NetworkSnapshot network,
    required void Function(Peer peer) onPeerFound,
    void Function(String message)? onLog,
  }) async {
    await stop();

    _deviceId = deviceId;
    _deviceName = deviceName;
    _network = network;
    _onPeerFound = onPeerFound;
    _onLog = onLog;

    // `Endpoint.any` accepts packets addressed to any local network interface,
    // useful when the current phone is either a hotspot client or hotspot host.
    _socket = await UDP.bind(Endpoint.any(port: const Port(discoveryPort)));

    // Operating systems normally protect applications from sending broadcast
    // unless explicitly enabled on the socket.
    _socket?.socket?.broadcastEnabled = true;
    _subscription = _socket
        ?.asStream()
        .listen(_handleDatagram, onError: _handleListenError);

    _onLog?.call('Discovery listening on UDP $discoveryPort');
    await broadcastPresence();
    _broadcastTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(broadcastPresence()),
    );
  }

  /// Sends a "hello" JSON message to everyone reachable on this local subnet.
  ///
  /// We try both the generic IPv4 broadcast and a subnet-derived directed
  /// broadcast. Android hotspot implementations differ, so attempting both
  /// improves discovery odds without changing the protocol.
  Future<void> broadcastPresence() async {
    final socket = _socket;
    if (socket == null || socket.closed) {
      return;
    }

    final payload = utf8.encode(jsonEncode(_discoveryPayload(discoveryHello)));
    await _send(
        socket, payload, Endpoint.broadcast(port: const Port(discoveryPort)));

    final directedBroadcast = _network?.broadcastAddress;
    if (directedBroadcast != null && directedBroadcast != '255.255.255.255') {
      await _send(
        socket,
        payload,
        Endpoint.unicast(
          InternetAddress(directedBroadcast),
          port: const Port(discoveryPort),
        ),
      );
    }
  }

  /// Closes timers, stream listeners, and the underlying operating system
  /// socket so a later restart can bind to the same port cleanly.
  Future<void> stop() async {
    _broadcastTimer?.cancel();
    _broadcastTimer = null;
    await _subscription?.cancel();
    _subscription = null;
    _socket?.close();
    _socket = null;
  }

  /// Centralized send helper: UDP does not guarantee delivery, so a send log
  /// only means bytes were handed to the network stack, not that a peer heard.
  Future<void> _send(UDP socket, List<int> payload, Endpoint endpoint) async {
    try {
      final sent = await socket.send(payload, endpoint);
      _onLog?.call('Discovery packet sent: $sent bytes to $endpoint');
    } catch (error) {
      _onLog?.call('Discovery send failed: $error');
    }
  }

  /// Parses one incoming datagram into a usable discovered peer.
  ///
  /// Discovery uses UTF-8 JSON because these packets are rare and small;
  /// readability is valuable here. Streaming audio uses binary instead because
  /// it produces many packets per second and every byte affects latency.
  void _handleDatagram(Datagram? datagram) {
    if (datagram == null) {
      return;
    }

    Map<String, Object?> message;
    try {
      message = jsonDecode(utf8.decode(datagram.data)) as Map<String, Object?>;
    } catch (_) {
      return;
    }

    // A LAN may contain arbitrary UDP programs. Only accept messages that opt
    // into PeerTalk's discovery protocol and the version this app understands.
    if (message['app'] != appProtocolName ||
        message['version'] != appProtocolVersion) {
      return;
    }

    final remoteDeviceId = message['deviceId'] as String?;
    // Phones receive their own broadcast on many networks; self-filtering keeps
    // the local device from appearing as a selectable remote peer.
    if (remoteDeviceId == null || remoteDeviceId == _deviceId) {
      return;
    }

    // Prefer the advertised Wi-Fi IP for clarity, but the source address of a
    // received datagram is an excellent fallback and often more authoritative.
    final remoteIp = (message['ip'] as String?)?.trim();
    final peer = Peer(
      id: remoteDeviceId,
      name: (message['name'] as String?)?.trim().isNotEmpty == true
          ? (message['name'] as String).trim()
          : 'Peer ${datagram.address.address}',
      ip: remoteIp?.isNotEmpty == true ? remoteIp! : datagram.address.address,
      audioPort: _readPort(message['audioPort'], audioPort),
      discoveryPort: _readPort(message['discoveryPort'], discoveryPort),
      lastSeen: DateTime.now(),
    );

    _onPeerFound?.call(peer);
    _onLog?.call('Peer ${peer.name} seen at ${peer.endpoint}');

    // A directed response means the announcing phone sees us immediately,
    // rather than waiting until our next periodic broadcast.
    if (message['type'] == discoveryHello) {
      unawaited(_replyTo(datagram.address, peer.discoveryPort));
    }
  }

  /// Answers a discovery request directly at its observed source address.
  Future<void> _replyTo(InternetAddress address, int port) async {
    final socket = _socket;
    if (socket == null || socket.closed) {
      return;
    }
    final payload = utf8.encode(jsonEncode(_discoveryPayload(discoveryHere)));
    await _send(
      socket,
      payload,
      Endpoint.unicast(address, port: Port(port)),
    );
  }

  /// Description sent over the LAN; no personal account or server token exists.
  Map<String, Object?> _discoveryPayload(String type) {
    return <String, Object?>{
      'app': appProtocolName,
      'version': appProtocolVersion,
      'type': type,
      'deviceId': _deviceId,
      'name': _deviceName,
      'ip': _network?.primaryIp,
      'audioPort': audioPort,
      'discoveryPort': discoveryPort,
      'sentAt': DateTime.now().toUtc().toIso8601String(),
    };
  }

  /// Be tolerant of a future or manually-crafted JSON message containing a
  /// numeric port as either JSON number or string.
  int _readPort(Object? value, int fallback) {
    if (value is int && value > 0) {
      return value;
    }
    if (value is String) {
      return int.tryParse(value) ?? fallback;
    }
    return fallback;
  }

  void _handleListenError(Object error) {
    _onLog?.call('Discovery listener error: $error');
  }
}
