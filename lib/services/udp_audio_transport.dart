import 'dart:async';
import 'dart:io';

import 'package:udp/udp.dart';

import '../models/audio_packet.dart';
import '../models/peer.dart';
import 'app_constants.dart';
import 'debug_log_service.dart';

/// One session-aware UDP transport for both transmitting and receiving audio.
///
/// This class deliberately transports bytes without deciding call policy.
/// It knows addresses and datagrams, while [CallController] decides whether a
/// decoded packet belongs to the accepted session and may reach the speaker.
/// Separating those responsibilities prevents stale or foreign audio from
/// being played merely because it arrived on the audio port.
class UdpAudioTransport {
  UdpAudioTransport({required DebugLogService logs}) : _logs = logs;

  final DebugLogService _logs;

  /// A single bound socket can listen and also send outgoing unicast packets.
  UDP? _socket;
  StreamSubscription<Datagram?>? _subscription;
  void Function(AudioPacket packet)? _onPacket;
  // Audio may produce many packets each second. These counts throttle logs so
  // diagnostics remain useful without forcing a UI redraw for every sample.
  int _sentCount = 0;
  int _receivedCount = 0;

  /// Opens the local audio mailbox; it does not start microphone or speaker.
  Future<void> start({
    required void Function(AudioPacket packet) onPacket,
  }) async {
    await stop();
    _onPacket = onPacket;
    try {
      _socket = await UDP.bind(Endpoint.any(port: const Port(audioPort)));
      _subscription =
          _socket?.asStream().listen(_handleDatagram, onError: _handleError);
      _logs.info('Audio transport listening on UDP $audioPort');
    } catch (error) {
      _logs.error('Unable to bind audio port $audioPort: $error');
      rethrow;
    }
  }

  /// Encodes and unicasts one speech fragment to the peer's audio port.
  ///
  /// UDP send completes once handed to the network stack; it is not proof that
  /// the receiver heard it. Sequence statistics on the other phone reveal loss.
  Future<void> send(AudioPacket packet, Peer peer) async {
    final socket = _socket;
    if (socket == null || socket.closed) {
      return;
    }
    try {
      await socket.send(
        packet.encode(),
        Endpoint.unicast(
          InternetAddress(peer.ipAddress),
          port: Port(peer.audioPort),
        ),
      );
      _sentCount += 1;
      if (_sentCount % 25 == 0) {
        _logs.packet('Audio sent seq=${packet.sequenceNumber}');
      }
    } catch (error) {
      _logs.error('Audio send failed: $error');
    }
  }

  /// Releases the socket and subscription during controller shutdown.
  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    _socket?.close();
    _socket = null;
  }

  /// Converts incoming datagram bytes into protocol objects when possible.
  void _handleDatagram(Datagram? datagram) {
    if (datagram == null) {
      return;
    }
    final packet = AudioPacket.decode(
      datagram.data,
      sourceIp: datagram.address.address,
    );
    if (packet == null) {
      return;
    }
    _receivedCount += 1;
    if (_receivedCount % 25 == 0) {
      _logs.packet('Audio received seq=${packet.sequenceNumber}');
    }
    _onPacket?.call(packet);
  }

  void _handleError(Object error) {
    _logs.error('Audio receive error: $error');
  }
}
