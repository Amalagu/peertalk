import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/peer.dart';
import 'app_constants.dart';
import 'debug_log_service.dart';

/// Maintains the live LAN peer list separately from packet discovery.
///
/// Discovery refreshes [lastSeen]. This registry removes automatically found
/// peers after their announcements stop, so switching networks does not leave
/// unreachable phones appearing online. Manual peers remain until app restart.
class PeerRegistry extends ChangeNotifier {
  PeerRegistry({required DebugLogService logs}) : _logs = logs;

  final DebugLogService _logs;

  /// A map provides fast replacement when another announcement for the same
  /// device arrives. The map key is a temporary device identifier, not login.
  final Map<String, Peer> _peers = <String, Peer>{};
  Timer? _staleTimer;
  int staleAfterSeconds = stalePeerAfterSeconds;

  List<Peer> get peers {
    final values = _peers.values.toList(growable: false);
    values.sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
    return values;
  }

  /// Begins periodic housekeeping independently of incoming announcements.
  void start() {
    _staleTimer ??= Timer.periodic(
      const Duration(seconds: 1),
      (_) => removeStalePeers(),
    );
  }

  /// Leaves several chances for broadcasts to arrive before hiding a peer.
  ///
  /// If the user selects a longer announcement interval, the expiry time must
  /// grow with it or healthy devices would repeatedly disappear from the list.
  void updateStaleTimeout(int discoveryIntervalSeconds) {
    staleAfterSeconds = discoveryIntervalSeconds * 3 + 2;
  }

  /// Inserts a new peer or refreshes the existing record for its device/IP.
  ///
  /// Matching by both ID and address handles a manual entry being replaced by
  /// a real announcement, or a peer acquiring a refreshed representation.
  void upsert(Peer peer) {
    String? matchingKey;
    for (final entry in _peers.entries) {
      if (entry.value.id == peer.id ||
          entry.value.ipAddress == peer.ipAddress) {
        matchingKey = entry.key;
        break;
      }
    }
    final isNew = matchingKey == null;
    if (matchingKey != null && matchingKey != peer.id) {
      _peers.remove(matchingKey);
    }
    _peers[peer.id] = peer;
    if (isNew) {
      _logs.info('Peer available: ${peer.name} at ${peer.callEndpoint}');
    }
    notifyListeners();
  }

  /// Finds the best destination for signaling/audio after a call identifies a
  /// remote device. IP matching supports the manual-IP fallback case.
  Peer? findByIdOrIp(String id, String ipAddress) {
    for (final peer in _peers.values) {
      if (peer.id == id || peer.ipAddress == ipAddress) {
        return peer;
      }
    }
    return null;
  }

  /// Ages out automatically discovered devices that stopped announcing.
  ///
  /// Manually entered endpoints are retained: the point of that fallback is
  /// to remain callable even on networks that block UDP broadcast.
  void removeStalePeers() {
    final threshold =
        DateTime.now().subtract(Duration(seconds: staleAfterSeconds));
    final removed = _peers.values
        .where((peer) => !peer.isManual && peer.lastSeen.isBefore(threshold))
        .toList(growable: false);
    for (final peer in removed) {
      _peers.remove(peer.id);
      _logs.warning('Peer timed out: ${peer.name}');
    }
    if (removed.isNotEmpty) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _staleTimer?.cancel();
    super.dispose();
  }
}
