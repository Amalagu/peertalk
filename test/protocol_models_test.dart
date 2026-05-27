import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:peer_talk/models/audio_packet.dart';
import 'package:peer_talk/models/audio_statistics.dart';
import 'package:peer_talk/models/control_packet.dart';

/// Protocol unit tests do not require microphones or two Android phones.
///
/// They prove that the bytes/JSON one phone sends can be decoded into the same
/// identity and payload on another phone. Physical testing is still needed for
/// permissions, hotspot routing, speaker output, and real latency.
void main() {
  group('AudioPacket', () {
    test('round trips session metadata and PCM payload', () {
      // This stands in for one small PCM fragment created by the recorder.
      final original = AudioPacket(
        sessionId: 'session-42',
        senderId: 'phone-a',
        sequenceNumber: 27,
        timestamp: 1730000000000,
        payload: Uint8List.fromList(<int>[1, 2, 3, 250]),
      );

      // `encode` represents the sending phone; `decode` represents the remote
      // socket supplying its observed source address.
      final parsed = AudioPacket.decode(
        original.encode(),
        sourceIp: '192.168.43.1',
      );

      expect(parsed, isNotNull);
      expect(parsed!.sessionId, original.sessionId);
      expect(parsed.senderId, original.senderId);
      expect(parsed.sequenceNumber, original.sequenceNumber);
      expect(parsed.timestamp, original.timestamp);
      expect(parsed.sourceIp, '192.168.43.1');
      expect(parsed.payload, original.payload);
    });

    test('rejects data without a V2 audio header', () {
      // Random UDP bytes must never be mistaken for speaker-ready PCM.
      expect(
        AudioPacket.decode(Uint8List.fromList(<int>[0, 1]), sourceIp: 'x'),
        isNull,
      );
    });
  });

  group('ControlPacket', () {
    test('round trips call signaling fields and metadata', () {
      // Invitations are infrequent readable JSON rather than binary media.
      final original = ControlPacket(
        type: ControlPacketType.callInvite,
        sessionId: 'call-a',
        senderId: 'phone-a',
        senderName: 'Kitchen',
        targetId: 'phone-b',
        timestamp: DateTime.utc(2026, 5, 27, 10),
        metadata: const <String, Object?>{
          'mode': 'full_duplex',
          'sampleRate': 16000,
        },
      );

      final parsed = ControlPacket.decode(
        original.encode(),
        sourceIp: '192.168.1.4',
      );

      expect(parsed, isNotNull);
      expect(parsed!.type, ControlPacketType.callInvite);
      expect(parsed.sessionId, 'call-a');
      expect(parsed.targetId, 'phone-b');
      expect(parsed.sourceIp, '192.168.1.4');
      expect(parsed.metadata['mode'], 'full_duplex');
    });
  });

  test('AudioStatistics detects sequence gaps', () {
    // Receiving sequence 5 after 2 means packets numbered 3 and 4 were lost
    // or delayed; this is how the active-call quality percentage is derived.
    final statistics = AudioStatistics()
      ..observeSequence(1)
      ..observeSequence(2)
      ..observeSequence(5);

    expect(statistics.receivedPackets, 3);
    expect(statistics.missingPackets, 2);
    expect(statistics.packetLossPercent, closeTo(40, 0.001));
  });
}
