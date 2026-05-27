import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/debug_log_entry.dart';
import '../models/network_snapshot.dart';
import '../models/peer.dart';
import 'audio_capture_service.dart';
import 'audio_playback_service.dart';
import 'network_info_service.dart';
import 'peer_discovery_service.dart';
import 'udp_audio_receiver.dart';
import 'udp_audio_sender.dart';
import 'app_constants.dart';

/// UI-facing phases of the push-to-talk workflow.
///
/// This is deliberately not a phone-call signalling protocol: version 1 has
/// no ring/answer/hang-up exchange. "Connected" means the user selected an IP
/// endpoint and the app is ready to exchange UDP audio with it.
enum CallStatus {
  starting,
  permissionNeeded,
  searching,
  peerFound,
  connected,
  sendingAudio,
  receivingAudio,
  error,
}

/// Keeps display wording separate from the state value used in decisions.
extension CallStatusLabel on CallStatus {
  String get label {
    switch (this) {
      case CallStatus.starting:
        return 'Starting';
      case CallStatus.permissionNeeded:
        return 'Permission needed';
      case CallStatus.searching:
        return 'Searching';
      case CallStatus.peerFound:
        return 'Peer found';
      case CallStatus.connected:
        return 'Connected';
      case CallStatus.sendingAudio:
        return 'Sending audio';
      case CallStatus.receivingAudio:
        return 'Receiving audio';
      case CallStatus.error:
        return 'Error';
    }
  }
}

/// The application's coordinator and its single source of visible state.
///
/// Flutter widgets should describe the screen, not manage socket lifetimes or
/// microphone streams. This controller composes six focused services:
///
/// - [NetworkInfoService] reads this phone's LAN metadata.
/// - [PeerDiscoveryService] announces/finds phones on the LAN.
/// - [UdpAudioSender] sends captured samples to the chosen peer.
/// - [UdpAudioReceiver] validates incoming audio packets.
/// - [AudioCaptureService] streams bytes from the microphone.
/// - [AudioPlaybackService] plays valid received bytes.
///
/// Extending [ChangeNotifier] is Flutter's small built-in state pattern:
/// after a state change, [notifyListeners] asks the `AnimatedBuilder` in
/// `main.dart` to rebuild with the latest fields.
class CallController extends ChangeNotifier {
  CallController({
    NetworkInfoService? networkInfoService,
    PeerDiscoveryService? discoveryService,
    UdpAudioSender? audioSender,
    UdpAudioReceiver? audioReceiver,
    AudioCaptureService? audioCapture,
    AudioPlaybackService? audioPlayback,
  })  : _networkInfoService = networkInfoService ?? NetworkInfoService(),
        _discoveryService = discoveryService ?? PeerDiscoveryService(),
        _audioSender = audioSender ?? UdpAudioSender(),
        _audioReceiver = audioReceiver ?? UdpAudioReceiver(),
        _audioCapture = audioCapture ?? AudioCaptureService(),
        _audioPlayback = audioPlayback ?? AudioPlaybackService();

  final NetworkInfoService _networkInfoService;
  final PeerDiscoveryService _discoveryService;
  final UdpAudioSender _audioSender;
  final UdpAudioReceiver _audioReceiver;
  final AudioCaptureService _audioCapture;
  final AudioPlaybackService _audioPlayback;

  /// A temporary session identity, not an account or hardware identifier.
  /// It is included in discovery packets so a phone ignores its own broadcast.
  final String deviceId =
      '${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 32)}';

  /// Mutable private collections exposed through unmodifiable getters below;
  /// widgets may display them but may not change controller state by accident.
  final List<Peer> _peers = <Peer>[];
  final List<DebugLogEntry> _logs = <DebugLogEntry>[];

  NetworkSnapshot? _networkSnapshot;
  Peer? _selectedPeer;
  CallStatus _status = CallStatus.starting;
  Timer? _receivingTimer;
  bool _hasMicrophonePermission = false;
  bool _hasNetworkInfoPermission = false;
  bool _isSending = false;
  bool _isReceiving = false;
  bool _disposed = false;
  String? _errorMessage;

  // Public read-only state consumed by the widget tree.
  NetworkSnapshot? get networkSnapshot => _networkSnapshot;
  Peer? get selectedPeer => _selectedPeer;
  CallStatus get status => _status;
  bool get hasMicrophonePermission => _hasMicrophonePermission;
  bool get hasNetworkInfoPermission => _hasNetworkInfoPermission;
  bool get isSending => _isSending;
  bool get isReceiving => _isReceiving;
  String? get errorMessage => _errorMessage;
  List<Peer> get peers => List<Peer>.unmodifiable(_peers);
  List<DebugLogEntry> get logs => List<DebugLogEntry>.unmodifiable(_logs);
  String get deviceName => 'PeerTalk ${deviceId.substring(0, 6)}';

  /// Performs startup in dependency order.
  ///
  /// Permissions and LAN display come first so the user can diagnose their
  /// setup. Playback and receiver begin before discovery so an already-known
  /// manual-IP peer can transmit to this phone as soon as it is selected.
  Future<void> initialize() async {
    _log('PeerTalk starting on Android UDP ports $discoveryPort/$audioPort');
    await requestPermissions();
    await refreshNetworkInfo();

    try {
      await _audioPlayback.open(onLog: _log);
      await _audioReceiver.start(onPacket: _handleAudioPacket, onLog: _log);
      await startDiscovery();
    } catch (error) {
      _setError('Startup failed: $error');
    }
  }

  /// Requests Android runtime access required by native plugin APIs.
  ///
  /// The manifest declares capabilities at installation time; Android also
  /// requires sensitive capabilities to be granted by the person at runtime.
  /// Microphone is mandatory for transmitting. Location/Nearby Wi-Fi primarily
  /// controls access to Wi-Fi identifying details on modern Android versions;
  /// sockets can still work when some labels are unavailable.
  Future<void> requestPermissions() async {
    final microphone = await Permission.microphone.request();
    _hasMicrophonePermission = microphone.isGranted;

    if (Platform.isAndroid) {
      // Android's privacy model changed over releases: older versions gate
      // Wi-Fi metadata behind location; newer versions provide Nearby Wi-Fi.
      // Asking for both lets this Android-first MVP cover either behavior.
      final location = await Permission.locationWhenInUse.request();
      final nearbyWifi = await Permission.nearbyWifiDevices.request();
      _hasNetworkInfoPermission = location.isGranted || nearbyWifi.isGranted;
    } else {
      _hasNetworkInfoPermission = true;
    }

    if (!_hasMicrophonePermission) {
      _status = CallStatus.permissionNeeded;
      _log('Microphone permission is not granted', DebugLogLevel.warning);
    } else {
      _log('Microphone permission granted');
    }

    if (!_hasNetworkInfoPermission) {
      _log('Wi-Fi info permission is limited', DebugLogLevel.warning);
    } else {
      _log('Wi-Fi info permission granted');
    }
    _notify();
  }

  /// Re-reads Wi-Fi details because users may switch hotspot/router while the
  /// app remains open.
  Future<void> refreshNetworkInfo() async {
    _networkSnapshot = await _networkInfoService.load();
    final ip = _networkSnapshot?.primaryIp ?? 'unknown';
    _log('Network refreshed. Local IP: $ip');
    _notify();
  }

  /// Starts or restarts background LAN discovery announcements.
  ///
  /// Discovery is not required to exchange audio after manual IP selection; it
  /// is a convenience layer for learning a peer's current address.
  Future<void> startDiscovery() async {
    final network = _networkSnapshot;
    if (network == null) {
      await refreshNetworkInfo();
    }

    _status =
        _selectedPeer == null ? CallStatus.searching : CallStatus.connected;
    _notify();

    await _discoveryService.start(
      deviceId: deviceId,
      deviceName: deviceName,
      network: _networkSnapshot ?? const NetworkSnapshot(),
      onPeerFound: _upsertPeer,
      onLog: _log,
    );
  }

  /// User-triggered advertisement retry, useful immediately after a second
  /// phone joins the hotspot.
  Future<void> broadcastNow() async {
    await refreshNetworkInfo();
    await _discoveryService.broadcastPresence();
  }

  /// Establishes the destination for subsequent unicast audio datagrams.
  ///
  /// There is no UDP "connection handshake": this status communicates user
  /// intent and socket readiness, not verified reachability.
  Future<void> selectPeer(Peer peer) async {
    _selectedPeer = peer;
    _audioSender.configure(peer: peer, onLog: _log);
    await _audioSender.start();
    _status = CallStatus.connected;
    _log('Selected ${peer.name} at ${peer.endpoint}');
    _notify();
  }

  /// Provides the fallback path for networks that isolate broadcast traffic.
  ///
  /// Once an IPv4 address is supplied, sending unicast UDP audio does not
  /// depend on broadcast discovery at all.
  Future<void> connectManual(String ip) async {
    final cleanIp = ip.trim();
    if (!_isValidIpv4(cleanIp)) {
      _log('Manual IP rejected: $ip', DebugLogLevel.warning);
      return;
    }

    final peer = Peer(
      id: 'manual-$cleanIp',
      name: 'Manual peer',
      ip: cleanIp,
      audioPort: audioPort,
      discoveryPort: discoveryPort,
      lastSeen: DateTime.now(),
      isManual: true,
    );
    _upsertPeer(peer);
    await selectPeer(peer);
  }

  /// Begins the transmit half of half-duplex communication while held.
  ///
  /// "Half-duplex" is walkie-talkie behavior: this device either sends or
  /// listens at an instant, avoiding speaker-to-microphone feedback and
  /// keeping the first audio design easy to reason about.
  Future<void> startTalking() async {
    if (_isSending) {
      return;
    }
    if (!_hasMicrophonePermission) {
      _log('Cannot talk without microphone permission', DebugLogLevel.warning);
      await requestPermissions();
      return;
    }
    if (_selectedPeer == null) {
      _log('Select or enter a peer before talking', DebugLogLevel.warning);
      return;
    }

    _isSending = true;

    // Treat transmission as dominant: audio arriving during our own press is
    // later ignored, enforcing the same push-to-talk rule on both phones.
    _isReceiving = false;
    _status = CallStatus.sendingAudio;
    _notify();

    await _audioSender.start();
    await _audioCapture.start(
      onData: _sendCapturedAudio,
      onLog: _log,
    );
  }

  /// Releases the microphone stream and returns to listening readiness.
  Future<void> stopTalking() async {
    if (!_isSending) {
      return;
    }
    await _audioCapture.stop(onLog: _log);
    await _audioSender.stop();
    _isSending = false;
    _status =
        _selectedPeer == null ? CallStatus.peerFound : CallStatus.connected;
    _notify();
  }

  /// Debug entries are user-observable diagnostics, not persistent analytics.
  void clearLogs() {
    _logs.clear();
    _notify();
  }

  /// Gracefully releases microphones, players, timers, and sockets.
  ///
  /// Explicit cleanup matters for native resources: without it, reopening the
  /// screen can fail to rebind UDP ports or reacquire audio hardware.
  Future<void> shutdown() async {
    _receivingTimer?.cancel();
    await _audioCapture.close();
    await _audioPlayback.close();
    await _audioReceiver.stop();
    await _audioSender.close();
    await _discoveryService.stop();
  }

  @override
  void dispose() {
    _disposed = true;

    // Flutter's synchronous `dispose` API cannot await plugin cleanup. Fire the
    // asynchronous shutdown and block any late notifications with `_disposed`.
    unawaited(shutdown());
    super.dispose();
  }

  /// Hot audio callback: avoid awaiting network sends on the microphone stream
  /// so capture remains responsive even if a send takes a moment.
  void _sendCapturedAudio(Uint8List pcm) {
    unawaited(_audioSender.sendPcm(pcm));
  }

  /// Applies receive policy to a decoded incoming packet.
  ///
  /// If a peer is selected, unexpected IPs are ignored so other devices on the
  /// same test network cannot play through this phone. While transmitting, all
  /// playback is ignored to implement half-duplex operation.
  void _handleAudioPacket(AudioPacket packet) {
    final selectedIp = _selectedPeer?.ip;
    if (_isSending || (selectedIp != null && selectedIp != packet.senderIp)) {
      return;
    }

    _audioPlayback.enqueue(packet.payload);
    _isReceiving = true;
    _status = CallStatus.receivingAudio;
    _notify();

    _receivingTimer?.cancel();

    // UDP audio has no explicit "speaker stopped" control message. A short
    // quiet timeout changes the UI back after incoming packets cease.
    _receivingTimer = Timer(const Duration(milliseconds: 500), () {
      _isReceiving = false;
      _status =
          _selectedPeer == null ? CallStatus.peerFound : CallStatus.connected;
      _notify();
    });
  }

  /// Adds a newly discovered phone or refreshes an existing announcement.
  ///
  /// IP is included in the match because a manually-entered peer can later be
  /// discovered, and it should appear as the same selectable destination.
  void _upsertPeer(Peer peer) {
    final existingIndex = _peers.indexWhere(
      (candidate) => candidate.id == peer.id || candidate.ip == peer.ip,
    );
    if (existingIndex == -1) {
      _peers.add(peer);
    } else {
      _peers[existingIndex] = peer;
    }
    _peers.sort((a, b) => b.lastSeen.compareTo(a.lastSeen));

    if (_selectedPeer?.id == peer.id || _selectedPeer?.ip == peer.ip) {
      _selectedPeer = peer;
      _audioSender.configure(peer: peer, onLog: _log);
    }

    if (_selectedPeer == null && _status == CallStatus.searching) {
      _status = CallStatus.peerFound;
    }
    _notify();
  }

  /// Changes state and records a user-debuggable startup/transport failure.
  void _setError(String message) {
    _errorMessage = message;
    _status = CallStatus.error;
    _log(message, DebugLogLevel.error);
    _notify();
  }

  /// Maintains a bounded in-memory console. Limiting lines prevents an open app
  /// receiving packets for hours from continually growing memory usage.
  void _log([String? message, DebugLogLevel level = DebugLogLevel.info]) {
    if (message == null || message.isEmpty) {
      return;
    }
    _logs.add(DebugLogEntry(message: message, level: level));
    if (_logs.length > 250) {
      _logs.removeRange(0, _logs.length - 250);
    }
    _notify();
  }

  /// Minimal dotted IPv4 check for a manual local address such as
  /// `192.168.43.1`. DNS names and IPv6 are outside version 1's scope.
  bool _isValidIpv4(String value) {
    final parts = value.split('.');
    if (parts.length != 4) {
      return false;
    }
    for (final part in parts) {
      final parsed = int.tryParse(part);
      if (parsed == null || parsed < 0 || parsed > 255) {
        return false;
      }
    }
    return true;
  }

  /// Protects asynchronous plugin/socket callbacks from rebuilding a widget
  /// tree that Flutter has already disposed.
  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }
}
