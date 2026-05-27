import 'dart:convert';

import '../services/app_constants.dart';

/// JSON message kinds sent on the signaling UDP port.
///
/// Signaling answers "should these phones exchange audio, and is the peer
/// still alive?" It is kept apart from frequent audio bytes so a simple
/// signaling failure can be logged and reasoned about independently.
enum ControlPacketType {
  callInvite,
  callAccept,
  callReject,
  callEnd,
  heartbeat,
  heartbeatAck,
}

extension ControlPacketTypeWire on ControlPacketType {
  /// Stable all-caps protocol spelling visible in the debug panel and JSON.
  String get wireName {
    switch (this) {
      case ControlPacketType.callInvite:
        return 'CALL_INVITE';
      case ControlPacketType.callAccept:
        return 'CALL_ACCEPT';
      case ControlPacketType.callReject:
        return 'CALL_REJECT';
      case ControlPacketType.callEnd:
        return 'CALL_END';
      case ControlPacketType.heartbeat:
        return 'HEARTBEAT';
      case ControlPacketType.heartbeatAck:
        return 'HEARTBEAT_ACK';
    }
  }

  /// Parses only call messages understood by this version of PeerTalk.
  static ControlPacketType? fromWireName(String? value) {
    for (final type in ControlPacketType.values) {
      if (type.wireName == value) {
        return type;
      }
    }
    return null;
  }
}

/// A call signaling message transferred as UTF-8 JSON over UDP.
///
/// Audio is binary because it is frequent. Signaling messages are infrequent,
/// and JSON makes logs/debugging easier while developing the session protocol.
class ControlPacket {
  const ControlPacket({
    required this.type,
    required this.sessionId,
    required this.senderId,
    required this.senderName,
    required this.timestamp,
    this.targetId,
    this.metadata = const <String, Object?>{},
    this.sourceIp,
  });

  /// Action requested or acknowledged by this message.
  final ControlPacketType type;

  /// Call identity to which the action belongs.
  final String sessionId;

  /// Stable-for-this-run identity of the phone sending the datagram.
  final String senderId;

  /// Display label carried so invitations still look friendly before discovery.
  final String senderName;

  /// Intended receiver ID when known; null allows manually addressed calls.
  final String? targetId;

  /// Sending time written in UTC ISO text, convenient for human log inspection.
  final DateTime timestamp;

  /// Extensible negotiation details such as mode, sample rate, and port.
  final Map<String, Object?> metadata;

  /// Derived from the datagram; it is intentionally not encoded by the sender.
  final String? sourceIp;

  /// Produces readable UTF-8 JSON because signaling is infrequent and small.
  List<int> encode() => utf8.encode(jsonEncode(<String, Object?>{
        'app': appProtocolName,
        'version': appProtocolVersion,
        'type': type.wireName,
        'sessionId': sessionId,
        'senderId': senderId,
        'senderName': senderName,
        'targetId': targetId,
        'timestamp': timestamp.toUtc().toIso8601String(),
        'metadata': metadata,
      }));

  /// Validates and parses one control datagram.
  ///
  /// A null result means "not a message for this protocol" rather than a fatal
  /// application error; UDP sockets may legitimately receive unexpected data.
  static ControlPacket? decode(List<int> data, {required String sourceIp}) {
    try {
      final map = jsonDecode(utf8.decode(data)) as Map<String, Object?>;
      if (map['app'] != appProtocolName ||
          map['version'] != appProtocolVersion) {
        return null;
      }
      final type = ControlPacketTypeWire.fromWireName(map['type'] as String?);
      final sessionId = map['sessionId'] as String?;
      final senderId = map['senderId'] as String?;
      final senderName = map['senderName'] as String?;
      final timestamp = DateTime.tryParse(map['timestamp'] as String? ?? '');
      if (type == null ||
          sessionId == null ||
          senderId == null ||
          senderName == null ||
          timestamp == null) {
        return null;
      }
      return ControlPacket(
        type: type,
        sessionId: sessionId,
        senderId: senderId,
        senderName: senderName,
        targetId: map['targetId'] as String?,
        timestamp: timestamp,
        metadata: (map['metadata'] as Map?)?.cast<String, Object?>() ??
            const <String, Object?>{},
        sourceIp: sourceIp,
      );
    } catch (_) {
      return null;
    }
  }
}
