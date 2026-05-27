/// Running quality counters for the current received audio stream.
///
/// These are deliberately lightweight statistics rather than error
/// correction. UDP does not tell an application which datagrams vanished.
/// Because every audio packet has an increasing sequence number, seeing
/// packets 40 then 43 lets us infer that 41 and 42 did not arrive in time.
class AudioStatistics {
  /// Number of valid audio datagrams accepted for the current call.
  int receivedPackets = 0;

  /// Sequence-number gaps observed in received traffic.
  int missingPackets = 0;

  /// Packets received too late for the speaker buffer to use sensibly.
  int droppedLatePackets = 0;

  /// Largest sequence seen so far; older out-of-order packets do not lower it.
  int? _highestSequence;

  /// Records an arrival and calculates only forward gaps.
  ///
  /// A late packet can have a smaller number than [_highestSequence]. We still
  /// count it as received, while the playback buffer decides whether it is
  /// useful; we do not accidentally report a second gap for that packet.
  void observeSequence(int sequenceNumber) {
    final previous = _highestSequence;
    if (previous != null && sequenceNumber > previous + 1) {
      missingPackets += sequenceNumber - previous - 1;
    }
    if (previous == null || sequenceNumber > previous) {
      _highestSequence = sequenceNumber;
    }
    receivedPackets += 1;
  }

  /// Called by playback when sound arrived after its useful playout moment.
  void recordDroppedLate() {
    droppedLatePackets += 1;
  }

  /// Ideal received count implied by the sequence stream.
  int get expectedPackets => receivedPackets + missingPackets;

  /// Approximate transport loss shown during a call.
  ///
  /// This percentage measures missing sequence numbers, not perceived voice
  /// quality: a few tiny gaps may be unobtrusive, while jitter can sound poor
  /// even if every packet eventually arrives.
  double get packetLossPercent {
    if (expectedPackets == 0) {
      return 0;
    }
    return missingPackets * 100 / expectedPackets;
  }
}
