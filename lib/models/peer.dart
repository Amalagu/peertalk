import 'communication_mode.dart';

/// A remote PeerTalk device that audio can be sent to.
///
/// A peer is an endpoint, not a cloud account: its identity is meaningful only
/// while this local session is running and the devices remain on the same LAN.
class Peer {
  const Peer({
    required this.id,
    required this.name,
    required this.ipAddress,
    required this.audioPort,
    required this.controlPort,
    required this.discoveryPort,
    required this.lastSeen,
    this.supportedModes = const <CommunicationMode>{
      CommunicationMode.pushToTalk,
    },
    this.isManual = false,
  });

  /// Temporary identifier announced in discovery packets to ignore our own
  /// broadcast and distinguish two devices even if addresses later change.
  final String id;

  /// Friendly session name displayed in the list.
  final String name;

  /// IPv4 destination of the remote phone on the hotspot/router network.
  final String ipAddress;

  /// UDP destination for raw voice packets.
  ///
  /// An IP identifies a device on the LAN; a port identifies which service in
  /// that device should receive the datagram, much like a room number.
  final int audioPort;

  /// UDP destination for call setup, heartbeats, and call ending.
  ///
  /// Keeping signaling away from the busy audio port makes parsing simpler and
  /// lets logs distinguish conversation control from microphone traffic.
  final int controlPort;

  /// UDP destination for discovery replies.
  final int discoveryPort;

  /// Latest announcement time, enabling a UI to age out stale peers.
  ///
  /// UDP discovery has no permanent "disconnect" event. Silence for several
  /// announcement intervals is the evidence that a phone left this LAN.
  final DateTime lastSeen;

  /// Features advertised by this peer during LAN discovery.
  final Set<CommunicationMode> supportedModes;

  /// True when a user typed the address because broadcast discovery failed.
  final bool isManual;

  /// Human-readable IP-plus-port representation, e.g. `192.168.1.7:45455`.
  String get endpoint => '$ipAddress:$audioPort';

  /// Endpoint to which a `CALL_INVITE` or heartbeat is sent.
  String get callEndpoint => '$ipAddress:$controlPort';

  /// Capability test used before asking a peer for full-duplex audio.
  bool supports(CommunicationMode mode) => supportedModes.contains(mode);

  /// Convenient immutable update pattern for future peer-refresh behavior.
  Peer copyWith({
    String? id,
    String? name,
    String? ipAddress,
    int? audioPort,
    int? controlPort,
    int? discoveryPort,
    DateTime? lastSeen,
    Set<CommunicationMode>? supportedModes,
    bool? isManual,
  }) {
    return Peer(
      id: id ?? this.id,
      name: name ?? this.name,
      ipAddress: ipAddress ?? this.ipAddress,
      audioPort: audioPort ?? this.audioPort,
      controlPort: controlPort ?? this.controlPort,
      discoveryPort: discoveryPort ?? this.discoveryPort,
      lastSeen: lastSeen ?? this.lastSeen,
      supportedModes: supportedModes ?? this.supportedModes,
      isManual: isManual ?? this.isManual,
    );
  }
}
