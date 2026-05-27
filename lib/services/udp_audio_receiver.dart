import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:udp/udp.dart';

import 'app_constants.dart';

/// A validated voice packet recovered from bytes received through UDP.
///
/// Keeping transport metadata alongside the PCM payload means later versions
/// can reorder packets or estimate loss without modifying playback's API.
class AudioPacket {
  const AudioPacket({
    required this.senderIp,
    required this.sequence,
    required this.timestampMs,
    required this.payload,
  });

  /// Source IP read from the actual UDP datagram, not trusted JSON metadata.
  final String senderIp;
  final int sequence;
  final int timestampMs;

  /// Raw PCM16 bytes that can be fed to the audio player.
  final Uint8List payload;
}

/// Listens for binary voice datagrams on the fixed PeerTalk audio port.
///
/// This receiver is always open while the screen is alive so the other phone
/// may begin speaking without a separate "answer" action. Half-duplex policy
/// (ignore received audio while transmitting) belongs in [CallController].
class UdpAudioReceiver {
  UDP? _socket;
  StreamSubscription<Datagram?>? _subscription;
  void Function(AudioPacket packet)? _onPacket;
  void Function(String message)? _onLog;
  int _receivedPackets = 0;

  /// Binds the well-known audio port and begins delivering valid packets.
  Future<void> start({
    required void Function(AudioPacket packet) onPacket,
    void Function(String message)? onLog,
  }) async {
    await stop();
    _onPacket = onPacket;
    _onLog = onLog;
    _socket = await UDP.bind(Endpoint.any(port: const Port(audioPort)));
    _subscription =
        _socket?.asStream().listen(_handleDatagram, onError: _handleError);
    _onLog?.call('Audio receiver listening on UDP $audioPort');
  }

  /// Unsubscribes before closing the socket to prevent late callbacks during
  /// controller shutdown or a service restart.
  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    _socket?.close();
    _socket = null;
  }

  /// Rejects unrelated/malformed traffic before exposing payload bytes.
  void _handleDatagram(Datagram? datagram) {
    if (datagram == null || datagram.data.length < audioHeaderBytes) {
      return;
    }

    final data = datagram.data;
    // The magic marker and version are the receiving side of the protocol
    // contract described in `app_constants.dart`.
    if (data[0] != audioMagicP ||
        data[1] != audioMagicT ||
        data[2] != audioMagicA ||
        data[3] != audioMagicU ||
        data[4] != appProtocolVersion) {
      return;
    }

    final header = ByteData.sublistView(data);
    final payloadLength = header.getUint16(6);
    final payloadEnd = audioHeaderBytes + payloadLength;

    // Trust no network length field until checked against bytes actually read.
    if (payloadLength <= 0 || payloadEnd > data.length) {
      return;
    }

    final packet = AudioPacket(
      senderIp: datagram.address.address,
      sequence: header.getUint32(8),
      timestampMs: header.getUint32(12),
      payload: Uint8List.fromList(data.sublist(audioHeaderBytes, payloadEnd)),
    );
    _receivedPackets += 1;

    // Sampling logs preserves visibility without rendering dozens of lines a
    // second during ordinary conversation.
    if (_receivedPackets % 20 == 0) {
      _onLog?.call(
        'Audio packet received seq=${packet.sequence} '
        'bytes=${packet.payload.length} from ${packet.senderIp}',
      );
    }
    _onPacket?.call(packet);
  }

  void _handleError(Object error) {
    _onLog?.call('Audio receiver error: $error');
  }
}
