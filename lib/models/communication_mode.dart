/// The two audio interaction styles supported by PeerTalk.
///
/// Push-to-talk remains the conservative fallback: only the person holding the
/// button transmits. Full-duplex continuously transmits and receives once a
/// call is accepted, similar to a telephone call.
enum CommunicationMode {
  pushToTalk,
  fullDuplex,
}

extension CommunicationModeDisplay on CommunicationMode {
  /// Friendly wording used in buttons and status labels.
  ///
  /// UI text can change without breaking interoperability, which is why the
  /// network representation below is intentionally kept separate.
  String get label {
    switch (this) {
      case CommunicationMode.pushToTalk:
        return 'Push-to-talk';
      case CommunicationMode.fullDuplex:
        return 'Full-duplex';
    }
  }

  /// Stable protocol value placed in discovery and call-signaling JSON.
  ///
  /// Never send the enum's Dart spelling directly. An explicit wire name
  /// lets the code rename UI concepts later without confusing older phones.
  String get wireName {
    switch (this) {
      case CommunicationMode.pushToTalk:
        return 'push_to_talk';
      case CommunicationMode.fullDuplex:
        return 'full_duplex';
    }
  }

  /// Converts an incoming protocol value into an option the app understands.
  ///
  /// Falling back to push-to-talk is deliberate: it is the less demanding
  /// mode and remains usable when a peer is older or sent malformed metadata.
  static CommunicationMode fromWireName(String? value) {
    return value == CommunicationMode.fullDuplex.wireName
        ? CommunicationMode.fullDuplex
        : CommunicationMode.pushToTalk;
  }
}
