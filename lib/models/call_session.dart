import 'communication_mode.dart';

/// The lifecycle states for one call session.
///
/// "Ringing" has incoming/outgoing variants internally so the UI can show the
/// right actions. Both are presented to users as a ringing call.
enum CallStatus {
  idle,
  outgoingRinging,
  incomingRinging,
  connecting,
  connected,
  ended,
  failed,
}

extension CallStatusDisplay on CallStatus {
  /// Text deliberately hides implementation details such as who initiated
  /// ringing, while state remains precise enough to enable the right buttons.
  String get label {
    switch (this) {
      case CallStatus.idle:
        return 'Idle';
      case CallStatus.outgoingRinging:
        return 'Ringing';
      case CallStatus.incomingRinging:
        return 'Incoming call';
      case CallStatus.connecting:
        return 'Connecting';
      case CallStatus.connected:
        return 'Connected';
      case CallStatus.ended:
        return 'Ended';
      case CallStatus.failed:
        return 'Failed';
    }
  }

  /// True after acceptance while media and liveness checks may be running.
  bool get isActive =>
      this == CallStatus.connecting || this == CallStatus.connected;

  /// Terminal sessions remain displayed until the person taps Done.
  bool get isTerminal => this == CallStatus.ended || this == CallStatus.failed;
}

/// A unique conversation between two local-network peers.
///
/// A session ID is essential for UDP: late audio from an old call could arrive
/// after a new call begins. Matching packets to [sessionId] prevents those old
/// bytes from reaching the speaker.
class CallSession {
  const CallSession({
    required this.sessionId,
    required this.localPeerId,
    required this.remotePeerId,
    required this.remoteIp,
    required this.remoteName,
    required this.status,
    required this.mode,
    required this.sampleRate,
    required this.createdAt,
    this.startedAt,
    this.endedAt,
    this.lastHeartbeatAt,
    this.failureReason,
  });

  /// Globally unlikely-to-repeat value carried by control and audio packets.
  final String sessionId;

  /// Identity this phone advertised when the session was created.
  final String localPeerId;

  /// Identity expected on audio/control traffic from the other phone.
  final String remotePeerId;

  /// Last known LAN route for the other phone, e.g. `192.168.43.27`.
  final String remoteIp;

  /// Human-facing device name captured for stable call-screen display.
  final String remoteName;

  /// Current call-state-machine position.
  final CallStatus status;

  /// Chosen microphone behavior for this call, negotiated in the invitation.
  final CommunicationMode mode;

  /// PCM samples per second agreed for both recorder and speaker.
  final int sampleRate;

  /// When the invitation/incoming ringing record was first created.
  final DateTime createdAt;

  /// Filled when audio is successfully activated, used for call duration.
  final DateTime? startedAt;

  /// Filled once a call ends or fails.
  final DateTime? endedAt;

  /// Last confirmation that the peer answered a heartbeat or sent one.
  final DateTime? lastHeartbeatAt;

  /// Explanatory result displayed on ended/failed call surfaces.
  final String? failureReason;

  /// Creates a new immutable state snapshot while keeping call identity fixed.
  ///
  /// Widgets may render an old snapshot while a new one is emitted. Immutable
  /// session objects make such state transitions predictable and debuggable.
  CallSession copyWith({
    String? remotePeerId,
    String? remoteIp,
    String? remoteName,
    CallStatus? status,
    CommunicationMode? mode,
    int? sampleRate,
    DateTime? startedAt,
    DateTime? endedAt,
    DateTime? lastHeartbeatAt,
    String? failureReason,
  }) {
    return CallSession(
      sessionId: sessionId,
      localPeerId: localPeerId,
      remotePeerId: remotePeerId ?? this.remotePeerId,
      remoteIp: remoteIp ?? this.remoteIp,
      remoteName: remoteName ?? this.remoteName,
      status: status ?? this.status,
      mode: mode ?? this.mode,
      sampleRate: sampleRate ?? this.sampleRate,
      createdAt: createdAt,
      startedAt: startedAt ?? this.startedAt,
      endedAt: endedAt ?? this.endedAt,
      lastHeartbeatAt: lastHeartbeatAt ?? this.lastHeartbeatAt,
      failureReason: failureReason ?? this.failureReason,
    );
  }

  /// Elapsed connected time; ringing alone is deliberately not billed as talk
  /// time, so a call that was never accepted reads `00:00`.
  Duration get duration {
    final start = startedAt;
    if (start == null) {
      return Duration.zero;
    }
    return (endedAt ?? DateTime.now()).difference(start);
  }
}
