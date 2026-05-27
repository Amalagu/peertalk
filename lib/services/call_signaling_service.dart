import 'dart:async';
import 'dart:io';

import 'package:udp/udp.dart';

import '../models/control_packet.dart';
import '../models/peer.dart';
import 'app_constants.dart';
import 'debug_log_service.dart';

/// Transfers low-frequency call-control messages on a dedicated UDP port.
///
/// Invites and heartbeats are intentionally repeated by [CallController]:
/// UDP is fast and local, but it does not promise a single datagram arrives.
class CallSignalingService {
  CallSignalingService({required DebugLogService logs}) : _logs = logs;

  final DebugLogService _logs;

  /// Control traffic owns a socket separate from discovery and PCM audio.
  UDP? _socket;
  StreamSubscription<Datagram?>? _subscription;
  void Function(ControlPacket packet)? _onPacket;

  /// Begins receiving call-control datagrams on the known signaling port.
  ///
  /// UDP is connectionless: `bind` does not connect to a peer. It merely
  /// creates this phone's mailbox, while [send] can target any discovered IP.
  Future<void> start({
    required void Function(ControlPacket packet) onPacket,
  }) async {
    await stop();
    _onPacket = onPacket;
    try {
      _socket = await UDP.bind(Endpoint.any(port: const Port(controlPort)));
      _subscription =
          _socket?.asStream().listen(_handleDatagram, onError: _handleError);
      _logs.info('Call signaling listening on UDP $controlPort');
    } catch (error) {
      _logs.error('Unable to bind call-control port $controlPort: $error');
      rethrow;
    }
  }

  /// Sends one signaling action directly to a selected peer's IP and port.
  ///
  /// This is unicast, unlike discovery broadcast, because by the time a Call
  /// button is used the intended receiver is already known.
  Future<void> send(ControlPacket packet, Peer peer) async {
    final socket = _socket;
    if (socket == null || socket.closed) {
      _logs.error('Call-control socket is not available');
      return;
    }
    try {
      await socket.send(
        packet.encode(),
        Endpoint.unicast(
          InternetAddress(peer.ipAddress),
          port: Port(peer.controlPort),
        ),
      );
      _logs.packet('${packet.type.wireName} sent to ${peer.name}');
    } catch (error) {
      _logs.error('Could not send ${packet.type.wireName}: $error');
    }
  }

  /// Stops listening and releases Android's port so another lifecycle can bind.
  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    _socket?.close();
    _socket = null;
  }

  /// Rejects invalid bytes and forwards valid protocol objects to the state
  /// controller, which decides whether they belong to the current session.
  void _handleDatagram(Datagram? datagram) {
    if (datagram == null) {
      return;
    }
    final packet = ControlPacket.decode(
      datagram.data,
      sourceIp: datagram.address.address,
    );
    if (packet == null) {
      return;
    }
    _logs.packet('${packet.type.wireName} received from ${packet.senderName}');
    _onPacket?.call(packet);
  }

  void _handleError(Object error) {
    _logs.error('Call signaling receive error: $error');
  }
}
