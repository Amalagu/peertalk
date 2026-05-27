/// A remote PeerTalk device that audio can be sent to.
///
/// A peer is an endpoint, not a cloud account: its identity is meaningful only
/// while this local session is running and the devices remain on the same LAN.
class Peer {
  const Peer({
    required this.id,
    required this.name,
    required this.ip,
    required this.audioPort,
    required this.discoveryPort,
    required this.lastSeen,
    this.isManual = false,
  });

  /// Temporary identifier announced in discovery packets to ignore our own
  /// broadcast and distinguish two devices even if addresses later change.
  final String id;

  /// Friendly session name displayed in the list.
  final String name;

  /// IPv4 destination of the remote phone on the hotspot/router network.
  final String ip;

  /// UDP destination for raw voice packets.
  final int audioPort;

  /// UDP destination for discovery replies.
  final int discoveryPort;

  /// Latest announcement time, enabling a UI to age out stale peers later.
  final DateTime lastSeen;

  /// True when a user typed the address because broadcast discovery failed.
  final bool isManual;

  /// Human-readable IP-plus-port representation, e.g. `192.168.1.7:45455`.
  String get endpoint => '$ip:$audioPort';

  /// Convenient immutable update pattern for future peer-refresh behavior.
  Peer copyWith({
    String? id,
    String? name,
    String? ip,
    int? audioPort,
    int? discoveryPort,
    DateTime? lastSeen,
    bool? isManual,
  }) {
    return Peer(
      id: id ?? this.id,
      name: name ?? this.name,
      ip: ip ?? this.ip,
      audioPort: audioPort ?? this.audioPort,
      discoveryPort: discoveryPort ?? this.discoveryPort,
      lastSeen: lastSeen ?? this.lastSeen,
      isManual: isManual ?? this.isManual,
    );
  }
}
