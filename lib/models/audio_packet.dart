import 'dart:convert';
import 'dart:typed_data';

import '../services/app_constants.dart';

/// Session-aware binary audio message used by Version 2 calls.
///
/// UDP gives the app a bag of bytes called a datagram. It does not describe
/// those bytes, retry missing messages, or sort messages that arrive out of
/// order. This model defines PeerTalk's byte agreement: a small fixed header,
/// a readable JSON identity block, and raw PCM microphone samples.
///
/// The controller creates one instance for each small slice of recorded audio.
/// The remote controller decodes it, verifies its session identity, and sends
/// its [payload] to the jitter-buffered speaker pipeline.
class AudioPacket {
  const AudioPacket({
    required this.sessionId,
    required this.senderId,
    required this.sequenceNumber,
    required this.timestamp,
    required this.payload,
    this.sourceIp,
    this.receivedAt,
  });

  /// Unique call identifier. This prevents delayed packets from an ended call
  /// from being played after the same people begin a new call.
  final String sessionId;

  /// Device identity of the microphone that produced the bytes.
  final String senderId;

  /// Per-call counter used to reorder packets and estimate missing audio.
  final int sequenceNumber;

  /// Sender-side wall-clock milliseconds, retained for protocol inspection
  /// and future latency metrics; ordering primarily uses [sequenceNumber].
  final int timestamp;

  /// Little-endian PCM16 audio data from `flutter_sound`.
  final Uint8List payload;

  /// Actual packet source address supplied by the receiving UDP socket.
  ///
  /// It is populated only after receiving and is more trustworthy for routing
  /// than a sender claiming an address inside its encoded metadata.
  final String? sourceIp;

  /// Local arrival time, useful when later measuring network jitter.
  final DateTime? receivedAt;

  /// Serializes this Dart object into the audio datagram transmitted over LAN.
  ///
  /// Packet metadata is JSON for transparency while PCM remains raw binary.
  /// Encoding every sample as JSON would multiply size and parsing cost. The
  /// header contains lengths so the receiver can safely find where metadata
  /// ends and speech bytes begin without guessing.
  Uint8List encode() {
    final metadata = Uint8List.fromList(utf8.encode(jsonEncode(<String, String>{
      'sessionId': sessionId,
      'senderId': senderId,
    })));
    final packet =
        Uint8List(audioHeaderBytes + metadata.length + payload.length);
    // ByteData writes multi-byte integer values into known byte offsets. Both
    // phones run this same app, so they interpret this same fixed layout.
    final header = ByteData.sublistView(packet);
    packet
      ..[0] = audioMagicP
      ..[1] = audioMagicT
      ..[2] = audioMagicA
      ..[3] = audioMagicVersion2;
    header
      ..setUint8(4, appProtocolVersion)
      ..setUint8(5, audioPacketType)
      ..setUint16(6, metadata.length)
      ..setUint16(8, payload.length)
      ..setUint32(10, sequenceNumber)
      ..setUint64(14, timestamp);
    packet.setRange(
        audioHeaderBytes, audioHeaderBytes + metadata.length, metadata);
    packet.setRange(audioHeaderBytes + metadata.length, packet.length, payload);
    return packet;
  }

  /// Parses an incoming datagram, returning `null` for traffic that is not a
  /// complete, valid PeerTalk V2 audio packet.
  ///
  /// Silently ignoring bad UDP data is useful on a LAN: another application
  /// may use nearby ports, a packet may be truncated, or an older PeerTalk
  /// version may transmit a different format. None should become loud noise.
  static AudioPacket? decode(Uint8List data, {required String sourceIp}) {
    // Check the inexpensive fixed signature before attempting JSON decoding.
    if (data.length < audioHeaderBytes ||
        data[0] != audioMagicP ||
        data[1] != audioMagicT ||
        data[2] != audioMagicA ||
        data[3] != audioMagicVersion2 ||
        data[4] != appProtocolVersion ||
        data[5] != audioPacketType) {
      return null;
    }
    try {
      final header = ByteData.sublistView(data);
      final metadataLength = header.getUint16(6);
      final payloadLength = header.getUint16(8);
      final metadataEnd = audioHeaderBytes + metadataLength;
      final payloadEnd = metadataEnd + payloadLength;
      // Length validation prevents reading beyond received bytes and excludes
      // packets which contain no playable samples.
      if (payloadLength == 0 || payloadEnd > data.length) {
        return null;
      }
      final metadata = jsonDecode(
        utf8.decode(data.sublist(audioHeaderBytes, metadataEnd)),
      ) as Map<String, Object?>;
      final sessionId = metadata['sessionId'] as String?;
      final senderId = metadata['senderId'] as String?;
      if (sessionId == null || senderId == null) {
        return null;
      }
      return AudioPacket(
        sessionId: sessionId,
        senderId: senderId,
        sequenceNumber: header.getUint32(10),
        timestamp: header.getUint64(14),
        payload: Uint8List.fromList(data.sublist(metadataEnd, payloadEnd)),
        sourceIp: sourceIp,
        receivedAt: DateTime.now(),
      );
    } catch (_) {
      return null;
    }
  }
}
