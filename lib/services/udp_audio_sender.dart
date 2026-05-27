import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:udp/udp.dart';

import '../models/peer.dart';
import 'app_constants.dart';

/// Converts captured PCM byte chunks into UDP datagrams for one selected peer.
///
/// UDP was chosen for real-time speech because it sends immediately and does
/// not pause newer audio while waiting to retransmit an older lost packet.
/// That tradeoff is appropriate for live voice: a missing instant of speech is
/// usually better than a growing delay. It also means UDP does *not* guarantee
/// arrival, order, or duplicate protection as TCP would.
class UdpAudioSender {
  /// A socket with an operating-system-chosen source port. The receiver only
  /// cares that packets are addressed to its known [audioPort].
  UDP? _socket;
  Peer? _peer;

  /// Helps a receiver detect packet order/loss in later improvements.
  int _sequence = 0;
  void Function(String message)? _onLog;

  /// Points future audio packets at the currently selected phone.
  void configure({
    required Peer peer,
    void Function(String message)? onLog,
  }) {
    _peer = peer;
    _onLog = onLog;
  }

  /// Creates the send socket once. UDP has no handshake with the selected peer.
  Future<void> start() async {
    if (_socket != null && !_socket!.closed) {
      return;
    }
    _socket = await UDP.bind(Endpoint.any());
    _onLog?.call('Audio sender ready');
  }

  /// Splits whatever-sized recorder chunk arrives into latency-friendly packets.
  ///
  /// An audio plugin buffer can be larger than a safe single network datagram.
  /// Slicing here ensures each payload remains below [maxAudioPayloadBytes].
  Future<void> sendPcm(Uint8List pcm) async {
    final socket = _socket;
    final peer = _peer;
    if (socket == null || socket.closed || peer == null || pcm.isEmpty) {
      return;
    }

    var offset = 0;
    while (offset < pcm.length) {
      final length = min(pcm.length - offset, maxAudioPayloadBytes);
      final packet = _packetize(pcm, offset, length);

      // `unicast` targets exactly one IP rather than every device on the LAN.
      // Audio should only be heard by the selected peer; only discovery uses
      // broadcast.
      final sent = await socket.send(
        packet,
        Endpoint.unicast(
          InternetAddress(peer.ip),
          port: Port(peer.audioPort),
        ),
      );
      // Logging every audio datagram would cause UI noise and unnecessary work.
      if (_sequence % 20 == 0) {
        _onLog?.call('Audio packet sent seq=$_sequence bytes=$sent');
      }
      offset += length;
      _sequence = (_sequence + 1) & 0xffffffff;
    }
  }

  /// There is no live UDP session to tear down when the talk button is
  /// released. Keeping the socket warm makes the next press respond quickly.
  Future<void> stop() async {}

  /// Releases the operating-system socket when the app/controller shuts down.
  Future<void> close() async {
    _socket?.close();
    _socket = null;
  }

  /// Builds one binary audio datagram: protocol header followed by PCM samples.
  ///
  /// [ByteData] writes multi-byte integers in a predictable byte order so both
  /// phones parse the exact same fields. The timestamp and sequence metadata
  /// are not required for playback yet, but make loss/jitter improvements
  /// possible without changing the packet format later.
  Uint8List _packetize(Uint8List pcm, int offset, int length) {
    final packet = Uint8List(audioHeaderBytes + length);
    packet[0] = audioMagicP;
    packet[1] = audioMagicT;
    packet[2] = audioMagicA;
    packet[3] = audioMagicU;

    final header = ByteData.view(packet.buffer);
    header
      ..setUint8(4, appProtocolVersion)
      // Reserved flags byte; zero until the protocol gains optional features.
      ..setUint8(5, 0)
      ..setUint16(6, length)
      ..setUint32(8, _sequence)
      // Only the lower 32 bits are needed for comparing nearby audio packets.
      ..setUint32(12, DateTime.now().millisecondsSinceEpoch & 0xffffffff);
    packet.setRange(audioHeaderBytes, audioHeaderBytes + length, pcm, offset);
    return packet;
  }
}
