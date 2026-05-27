import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/audio_packet.dart';
import '../models/audio_statistics.dart';
import '../models/call_session.dart';
import '../models/communication_mode.dart';
import '../models/control_packet.dart';
import '../models/debug_log_entry.dart';
import '../models/network_snapshot.dart';
import '../models/peer.dart';
import 'app_constants.dart';
import 'app_settings_service.dart';
import 'audio_capture_service.dart';
import 'audio_playback_service.dart';
import 'audio_route_service.dart';
import 'call_signaling_service.dart';
import 'debug_log_service.dart';
import 'network_info_service.dart';
import 'peer_discovery_service.dart';
import 'peer_registry.dart';
import 'udp_audio_transport.dart';

/// Coordinates discovery, signaling, media, settings, and visible call state.
///
/// Version 2 treats a selected peer and a call as different concepts. A peer
/// says "this phone appears reachable"; a [CallSession] says "both people
/// agreed to exchange media under this unique session ID."
class CallController extends ChangeNotifier {
  /// Wires the event-producing services into Flutter's rebuild notification.
  ///
  /// Neither the logging service nor peer registry knows anything about
  /// widgets. Relaying their changes here gives the UI one controller to watch.
  CallController() {
    _logs.addListener(_notify);
    _peerRegistry.addListener(_notify);
  }

  // Long-lived services are deliberately separated by concern:
  // - network info describes our LAN addressing;
  // - discovery finds possible conversation partners;
  // - signaling negotiates a call and checks liveness;
  // - audio transport carries already-recorded PCM packets;
  // - capture/playback/route interact with audio hardware.
  // The controller is the orchestration layer, not the implementation of each.
  final NetworkInfoService _networkInfoService = NetworkInfoService();
  final DebugLogService _logs = DebugLogService();
  final AppSettingsService settings = AppSettingsService();
  late final PeerRegistry _peerRegistry = PeerRegistry(logs: _logs);
  late final PeerDiscoveryService _discovery =
      PeerDiscoveryService(logs: _logs);
  late final CallSignalingService _signaling =
      CallSignalingService(logs: _logs);
  late final UdpAudioTransport _audioTransport = UdpAudioTransport(logs: _logs);
  late final AudioPlaybackService _audioPlayback =
      AudioPlaybackService(logs: _logs);
  late final AudioRouteService _audioRoute = AudioRouteService(logs: _logs);
  final AudioCaptureService _audioCapture = AudioCaptureService();

  /// Ephemeral identity advertised on this run of the app.
  ///
  /// PeerTalk has no accounts. Combining current time and randomness gives a
  /// practical collision-resistant label so two phones can reject their own
  /// broadcast and target signaling to a particular discovered instance.
  final String deviceId =
      '${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 32)}';

  // Model snapshots rendered by the UI. A selected peer is merely a potential
  // destination; a session exists only once ringing/call workflow has begun.
  NetworkSnapshot? _networkSnapshot;
  Peer? _selectedPeer;
  CallSession? _session;
  AudioStatistics _statistics = AudioStatistics();

  // Timers turn UDP's connectionless behavior into user-facing reliability:
  // invites repeat until answered, heartbeat detects vanished peers, duration
  // refreshes the screen, and receiving briefly lights an activity indicator.
  Timer? _inviteTimer;
  Timer? _callTimeoutTimer;
  Timer? _heartbeatTimer;
  Timer? _durationTimer;
  Timer? _receivingTimer;

  // Flags are simple renderable state derived from permission/audio activity.
  bool _hasMicrophonePermission = false;
  bool _hasNetworkInfoPermission = false;
  bool _initializing = true;
  bool _isSending = false;
  bool _isReceiving = false;
  bool _isMuted = false;
  bool _speakerphoneEnabled = true;
  bool _disposed = false;
  int _audioSequence = 0;
  String? _errorMessage;

  // Read-only accessors prevent widgets from mutating protocol/call state.
  NetworkSnapshot? get networkSnapshot => _networkSnapshot;
  Peer? get selectedPeer => _selectedPeer;
  CallSession? get session => _session;
  CallStatus get callStatus => _session?.status ?? CallStatus.idle;
  AudioStatistics get statistics => _statistics;
  List<Peer> get peers => _peerRegistry.peers;
  List<DebugLogEntry> get logs => _logs.entries;
  bool get hasMicrophonePermission => _hasMicrophonePermission;
  bool get hasNetworkInfoPermission => _hasNetworkInfoPermission;
  bool get initializing => _initializing;
  bool get isSending => _isSending;
  bool get isReceiving => _isReceiving;
  bool get isMuted => _isMuted;
  bool get speakerphoneEnabled => _speakerphoneEnabled;
  String? get errorMessage => _errorMessage;
  String get deviceName => settings.deviceName;

  /// Short summary shown on the home screen rather than every internal state.
  String get homeStatus {
    if (_initializing) {
      return 'Starting';
    }
    if (_errorMessage != null) {
      return 'Limited operation';
    }
    if (_session != null) {
      return _session!.status.label;
    }
    return peers.isEmpty ? 'Searching' : 'Ready';
  }

  /// Initializes long-lived sockets; media resources are acquired only in a
  /// connected call so browsing for peers does not occupy the speaker/mic.
  Future<void> initialize() async {
    await settings.load(
        defaultDeviceName: 'PeerTalk ${deviceId.substring(0, 6)}');
    _logs.setEnabled(settings.debugLogsEnabled);
    _speakerphoneEnabled = settings.speakerphoneEnabled;
    _peerRegistry
      ..updateStaleTimeout(settings.discoveryIntervalSeconds)
      ..start();
    _logs.info(
      'PeerTalk V2 starting on UDP ports '
      '$discoveryPort/$controlPort/$audioPort',
    );
    await requestPermissions();
    await refreshNetworkInfo();
    try {
      await _signaling.start(onPacket: _handleControlPacket);
      await _audioTransport.start(onPacket: _handleAudioPacket);
      await startDiscovery();
    } catch (error) {
      _setError('Startup failed: $error');
    }
    _initializing = false;
    _notify();
  }

  /// Requests Android runtime access needed for voice and useful Wi-Fi details.
  ///
  /// Internet access in the manifest is not a request to use the public
  /// internet: Android also gates local IP networking behind socket permission.
  /// Location/nearby-Wi-Fi permission affects network metadata and discovery
  /// diagnostics on modern Android versions; manual addressing remains useful.
  Future<void> requestPermissions() async {
    final microphone = await Permission.microphone.request();
    _hasMicrophonePermission = microphone.isGranted;
    if (Platform.isAndroid) {
      final location = await Permission.locationWhenInUse.request();
      final nearbyWifi = await Permission.nearbyWifiDevices.request();
      _hasNetworkInfoPermission = location.isGranted || nearbyWifi.isGranted;
    } else {
      _hasNetworkInfoPermission = true;
    }
    if (!_hasMicrophonePermission) {
      _logs.warning('Microphone blocked; receiving calls still works');
    }
    if (!_hasNetworkInfoPermission) {
      _logs
          .warning('Wi-Fi detail permission limited; manual IP remains usable');
    }
    _notify();
  }

  /// Reads the address assigned by the hotspot/router for display/discovery.
  Future<void> refreshNetworkInfo() async {
    _networkSnapshot = await _networkInfoService.load();
    _logs.info(
      'Network refreshed; local IP is ${_networkSnapshot?.primaryIp ?? 'unknown'}',
    );
    _notify();
  }

  /// (Re)opens periodic LAN announcements using current name and interval.
  Future<void> startDiscovery() async {
    try {
      await _discovery.start(
        deviceId: deviceId,
        deviceName: deviceName,
        network: _networkSnapshot ?? const NetworkSnapshot(),
        intervalSeconds: settings.discoveryIntervalSeconds,
        onPeerFound: _peerRegistry.upsert,
      );
    } catch (error) {
      _setError('Peer discovery unavailable: $error');
    }
  }

  /// User-requested refresh broadcasts immediately rather than waiting on the
  /// periodic discovery timer.
  Future<void> broadcastNow() async {
    await refreshNetworkInfo();
    await _discovery.broadcastPresence();
  }

  /// Records which peer the home/detail screen has chosen for a future call.
  void selectPeer(Peer peer) {
    _selectedPeer = peer;
    _notify();
  }

  /// Adds an endpoint without discovery, useful when a hotspot blocks broadcast.
  ///
  /// Only dotted IPv4 is accepted in this MVP because the current UDP
  /// discovery/call flow is intentionally scoped to local IPv4 networks.
  Future<void> addManualPeer(String input) async {
    final ipAddress = input.trim();
    if (!_isValidIpv4(ipAddress)) {
      _logs.warning('Manual IP rejected: $input');
      return;
    }
    final peer = Peer(
      id: 'manual-$ipAddress',
      name: 'Manual peer',
      ipAddress: ipAddress,
      audioPort: audioPort,
      controlPort: controlPort,
      discoveryPort: discoveryPort,
      lastSeen: DateTime.now(),
      supportedModes: const <CommunicationMode>{
        CommunicationMode.pushToTalk,
        CommunicationMode.fullDuplex,
      },
      isManual: true,
    );
    _peerRegistry.upsert(peer);
    selectPeer(peer);
  }

  /// Starts reliable-enough UDP ringing by repeating invites until an answer
  /// or timeout. A chosen session ID identifies every subsequent media packet.
  Future<void> callPeer(Peer peer) async {
    if (_session != null && !_session!.status.isTerminal) {
      _logs.warning('End the current call before starting another');
      return;
    }
    selectPeer(peer);
    final requestedMode = settings.mode == CommunicationMode.fullDuplex &&
            !peer.supports(CommunicationMode.fullDuplex)
        ? CommunicationMode.pushToTalk
        : settings.mode;
    if (requestedMode != settings.mode) {
      _logs.warning('Peer does not advertise full-duplex; using push-to-talk');
    }
    _statistics = AudioStatistics();
    _session = CallSession(
      sessionId: _newSessionId(),
      localPeerId: deviceId,
      remotePeerId: peer.id,
      remoteIp: peer.ipAddress,
      remoteName: peer.name,
      status: CallStatus.outgoingRinging,
      mode: requestedMode,
      sampleRate: settings.sampleRate,
      createdAt: DateTime.now(),
    );
    _logs.info('Calling ${peer.name} in ${requestedMode.label} mode');
    await _sendForCurrent(ControlPacketType.callInvite);
    _inviteTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(_repeatInvite()),
    );
    _callTimeoutTimer = Timer(
      const Duration(seconds: callInviteTimeoutSeconds),
      () => unawaited(_failCall('No answer')),
    );
    _notify();
  }

  Future<void> acceptIncomingCall() async {
    final current = _session;
    if (current == null || current.status != CallStatus.incomingRinging) {
      return;
    }
    _session = current.copyWith(status: CallStatus.connecting);
    _notify();
    // Acceptance is sent before opening media so the caller stops ringing
    // promptly; either side can then activate its identical local pipeline.
    await _sendForCurrent(ControlPacketType.callAccept);
    await _activateMedia();
  }

  /// Explicitly tells the caller to stop waiting, then keeps a finished result
  /// visible locally until it is dismissed.
  Future<void> rejectIncomingCall() async {
    if (_session?.status != CallStatus.incomingRinging) {
      return;
    }
    await _sendForCurrent(ControlPacketType.callReject);
    await _finishCall(CallStatus.ended, reason: 'Declined');
  }

  /// Ends an established or still-ringing session for both phones.
  Future<void> endCall() async {
    if (_session == null || _session!.status.isTerminal) {
      return;
    }
    await _sendForCurrent(ControlPacketType.callEnd);
    await _finishCall(CallStatus.ended, reason: 'Call ended');
  }

  /// Returns the UI to the discovery home after the ended result was read.
  void dismissFinishedCall() {
    if (_session?.status.isTerminal == true) {
      _session = null;
      _selectedPeer = null;
      _errorMessage = null;
      _notify();
    }
  }

  /// In push-to-talk calls the button opens capture only while held. In
  /// full-duplex calls microphone capture begins automatically after accept.
  Future<void> startTalking() async {
    final current = _session;
    if (current == null ||
        current.status != CallStatus.connected ||
        current.mode != CommunicationMode.pushToTalk ||
        _isMuted ||
        _isSending) {
      return;
    }
    if (!_hasMicrophonePermission) {
      await requestPermissions();
      return;
    }
    await _startCapture();
  }

  Future<void> stopTalking() async {
    if (_session?.mode != CommunicationMode.pushToTalk || !_isSending) {
      return;
    }
    await _audioCapture.stop(onLog: _logs.info);
    _isSending = false;
    _notify();
  }

  /// Controls microphone transmission without muting remote speaker playback.
  ///
  /// Full-duplex capture is continuous, so muting stops/restarts the recorder.
  /// In push-to-talk, mute simply prevents a new held-button transmission.
  Future<void> toggleMute() async {
    _isMuted = !_isMuted;
    if (_session?.mode == CommunicationMode.fullDuplex) {
      if (_isMuted) {
        await _audioCapture.stop(onLog: _logs.info);
        _isSending = false;
      } else if (_session?.status == CallStatus.connected) {
        await _startCapture();
      }
    }
    _notify();
  }

  /// Changes Android output routing immediately and persists next-call default.
  Future<void> toggleSpeakerphone() async {
    _speakerphoneEnabled = !_speakerphoneEnabled;
    await settings.setSpeakerphoneEnabled(_speakerphoneEnabled);
    if (_session?.status.isActive == true) {
      await _audioRoute.setSpeakerphone(_speakerphoneEnabled);
    }
    _notify();
  }

  // Settings methods keep UI widgets thin. Changes that affect advertised
  // identity or discovery cadence restart discovery so neighboring phones see
  // the new data; media format settings take effect on future calls only.
  Future<void> updateMode(CommunicationMode mode) async {
    await settings.setMode(mode);
    _notify();
  }

  Future<void> updateDeviceName(String name) async {
    await settings.setDeviceName(name);
    await startDiscovery();
    _notify();
  }

  Future<void> updateDiscoveryInterval(int seconds) async {
    await settings.setDiscoveryInterval(seconds);
    _peerRegistry.updateStaleTimeout(seconds);
    await startDiscovery();
    _notify();
  }

  Future<void> updateSampleRate(int rate) async {
    await settings.setSampleRate(rate);
    _notify();
  }

  Future<void> updateJitterBuffer(int milliseconds) async {
    await settings.setJitterBuffer(milliseconds);
    _notify();
  }

  Future<void> updateDebugLogs(bool enabled) async {
    await settings.setDebugLogsEnabled(enabled);
    _logs.setEnabled(enabled);
    _notify();
  }

  void clearLogs() => _logs.clear();

  /// Main signaling state-machine input.
  ///
  /// The signaling socket can receive messages from any LAN device. Filtering
  /// target/device/session values here is what confines changes to our call.
  Future<void> _handleControlPacket(ControlPacket packet) async {
    if (packet.senderId == deviceId ||
        (packet.targetId != null && packet.targetId != deviceId)) {
      return;
    }
    final peer = _peerFromPacket(packet);
    _peerRegistry.upsert(peer);
    final current = _session;
    switch (packet.type) {
      case ControlPacketType.callInvite:
        await _handleInvite(packet, peer);
        break;
      case ControlPacketType.callAccept:
        if (current?.sessionId == packet.sessionId &&
            current?.status == CallStatus.outgoingRinging) {
          _cancelInviteTimers();
          _session = current!.copyWith(
            remotePeerId: packet.senderId,
            remoteIp: peer.ipAddress,
            remoteName: peer.name,
            status: CallStatus.connecting,
          );
          _notify();
          // Audio starts only after the remote human has accepted. Until this
          // point outgoing ringing consumes no microphone/speaker resources.
          await _activateMedia();
        }
        break;
      case ControlPacketType.callReject:
        if (current?.sessionId == packet.sessionId &&
            current?.status == CallStatus.outgoingRinging) {
          await _failCall('Call rejected');
        }
        break;
      case ControlPacketType.callEnd:
        if (current?.sessionId == packet.sessionId) {
          await _finishCall(CallStatus.ended, reason: 'Remote ended call');
        }
        break;
      case ControlPacketType.heartbeat:
        if (current?.sessionId == packet.sessionId &&
            current?.status.isActive == true) {
          _touchHeartbeat();
          // Reply makes liveness symmetric: either side can recognize loss.
          await _sendForCurrent(ControlPacketType.heartbeatAck);
        }
        break;
      case ControlPacketType.heartbeatAck:
        if (current?.sessionId == packet.sessionId &&
            current?.status.isActive == true) {
          _touchHeartbeat();
          if (_session?.status == CallStatus.connecting) {
            _session = _session!.copyWith(status: CallStatus.connected);
            _notify();
          }
        }
        break;
    }
  }

  /// Handles a remote invitation, including simultaneous-call collisions.
  ///
  /// Both phones might tap Call at nearly the same instant. Because UDP has no
  /// server to arbitrate, a deterministic device-ID comparison makes both
  /// devices reach the same decision: one invitation survives, one switches
  /// to incoming ringing.
  Future<void> _handleInvite(ControlPacket packet, Peer peer) async {
    final existing = _session;
    if (existing != null && existing.sessionId == packet.sessionId) {
      if (existing.status.isActive) {
        await _sendForCurrent(ControlPacketType.callAccept);
      }
      return;
    }
    if (existing != null && !existing.status.isTerminal) {
      if (existing.status == CallStatus.outgoingRinging &&
          deviceId.compareTo(packet.senderId) > 0) {
        // Deterministic collision rule: the alphabetically lower device ID
        // keeps its outbound invitation; the higher ID becomes receiver.
        _cancelInviteTimers();
        _logs.warning('Simultaneous calls detected; showing incoming call');
      } else {
        await _sendControl(
          ControlPacketType.callReject,
          peer,
          sessionId: packet.sessionId,
          metadata: const <String, Object?>{'reason': 'busy'},
        );
        return;
      }
    }
    final mode = CommunicationModeDisplay.fromWireName(
      packet.metadata['mode'] as String?,
    );
    // The recipient adopts the invited format for this call. Unsupported or
    // absent rate metadata safely falls back to the common baseline format.
    final requestedRate = packet.metadata['sampleRate'] as int?;
    final rate = supportedSampleRates.contains(requestedRate)
        ? requestedRate!
        : audioSampleRate;
    _selectedPeer = peer;
    _statistics = AudioStatistics();
    _session = CallSession(
      sessionId: packet.sessionId,
      localPeerId: deviceId,
      remotePeerId: packet.senderId,
      remoteIp: peer.ipAddress,
      remoteName: peer.name,
      status: CallStatus.incomingRinging,
      mode: mode,
      sampleRate: rate,
      createdAt: DateTime.now(),
    );
    _logs.info('Incoming ${mode.label} call from ${peer.name}');
    _callTimeoutTimer?.cancel();
    _callTimeoutTimer = Timer(
      const Duration(seconds: callInviteTimeoutSeconds),
      () => unawaited(_finishCall(CallStatus.ended, reason: 'Missed call')),
    );
    _notify();
  }

  /// Prepares the media plane after the signaling plane has accepted a call.
  ///
  /// In networking terminology, signaling changes call state while media is
  /// the stream of actual voice data. Playback is opened for both modes;
  /// microphone capture starts immediately only for full-duplex mode.
  Future<void> _activateMedia() async {
    final current = _session;
    if (current == null) {
      return;
    }
    _cancelInviteTimers();
    try {
      await _audioRoute.beginCall(speakerphone: _speakerphoneEnabled);
      await _audioPlayback.open(sampleRate: current.sampleRate);
      _audioPlayback.configure(
        jitterMilliseconds: settings.jitterBufferMs,
        whenDroppedLate: () {
          _statistics.recordDroppedLate();
          _notify();
        },
      );
      _session = current.copyWith(
        status: CallStatus.connected,
        startedAt: DateTime.now(),
        lastHeartbeatAt: DateTime.now(),
      );
      _audioSequence = 0;
      _isMuted = false;
      _startHeartbeat();
      _durationTimer?.cancel();
      _durationTimer =
          Timer.periodic(const Duration(seconds: 1), (_) => _notify());
      if (current.mode == CommunicationMode.fullDuplex) {
        await _startCapture();
      }
      _logs.info('Call connected in ${current.mode.label} mode');
      _notify();
    } catch (error) {
      await _failCall('Could not start audio: $error');
    }
  }

  /// Starts PCM microphone capture and directs new bytes toward packetization.
  Future<void> _startCapture() async {
    final current = _session;
    if (current == null || !_hasMicrophonePermission || _isSending) {
      return;
    }
    await _audioCapture.start(
      onData: _sendAudioBytes,
      sampleRate: current.sampleRate,
      voiceCommunicationMode: current.mode == CommunicationMode.fullDuplex,
      onLog: _logs.info,
    );
    _isSending = true;
    _notify();
  }

  /// Splits arbitrary recorder chunks into bounded UDP audio datagrams.
  ///
  /// The audio plugin chooses when chunks arrive; UDP performance benefits from
  /// small packets below typical network MTU size. Every resulting datagram is
  /// independently identifiable by session and increasing sequence number.
  void _sendAudioBytes(Uint8List pcm) {
    final current = _session;
    final peer = _activePeer;
    if (current == null ||
        peer == null ||
        current.status != CallStatus.connected) {
      return;
    }
    var offset = 0;
    while (offset < pcm.length) {
      final count = min(maxAudioPayloadBytes, pcm.length - offset);
      final payload = Uint8List.fromList(pcm.sublist(offset, offset + count));
      final packet = AudioPacket(
        sessionId: current.sessionId,
        senderId: deviceId,
        sequenceNumber: _audioSequence++,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        payload: payload,
      );
      // Sending is intentionally not awaited inside this synchronous capture
      // callback: waiting would stall delivery of future microphone samples.
      unawaited(_audioTransport.send(packet, peer));
      offset += count;
    }
  }

  /// Validates received voice before allowing it into the speaker buffer.
  ///
  /// Session and sender tests are the safety boundary against late call audio
  /// or a different LAN peer. In push-to-talk, playing while this phone speaks
  /// is suppressed to preserve the half-duplex "one speaker at a time" model.
  void _handleAudioPacket(AudioPacket packet) {
    final current = _session;
    if (current == null ||
        current.status != CallStatus.connected ||
        packet.sessionId != current.sessionId ||
        packet.senderId != current.remotePeerId ||
        (current.mode == CommunicationMode.pushToTalk && _isSending)) {
      return;
    }
    _statistics.observeSequence(packet.sequenceNumber);
    _audioPlayback.enqueue(packet);
    _isReceiving = true;
    _receivingTimer?.cancel();
    _receivingTimer = Timer(const Duration(milliseconds: 400), () {
      _isReceiving = false;
      _notify();
    });
    _notify();
  }

  /// Repeats unanswered invitations because UDP provides no delivery receipt.
  Future<void> _repeatInvite() async {
    if (_session?.status == CallStatus.outgoingRinging) {
      await _sendForCurrent(ControlPacketType.callInvite);
    }
  }

  /// Starts the lightweight liveness conversation for an accepted call.
  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(
      const Duration(seconds: heartbeatIntervalSeconds),
      (_) => unawaited(_heartbeatTick()),
    );
    unawaited(_sendForCurrent(ControlPacketType.heartbeat));
  }

  /// Sends a heartbeat and degrades/ends the call when replies disappear.
  ///
  /// "Connecting" during a short interruption signals recovery effort to the
  /// user without immediately tearing down media during a transient Wi-Fi blip.
  Future<void> _heartbeatTick() async {
    if (_session == null || !_session!.status.isActive) {
      return;
    }
    await _sendForCurrent(ControlPacketType.heartbeat);
    final current = _session;
    if (current == null || !current.status.isActive) {
      return;
    }
    final last =
        current.lastHeartbeatAt ?? current.startedAt ?? current.createdAt;
    final age = DateTime.now().difference(last).inSeconds;
    if (age >= heartbeatFailureAfterSeconds) {
      await _failCall('Peer connection lost');
    } else if (age >= heartbeatReconnectAfterSeconds &&
        current.status == CallStatus.connected) {
      _session = current.copyWith(status: CallStatus.connecting);
      _logs.warning('Network interruption; reconnecting');
      _notify();
    }
  }

  /// Records proof that the remote PeerTalk process is still reachable.
  void _touchHeartbeat() {
    final current = _session;
    if (current != null) {
      _session = current.copyWith(lastHeartbeatAt: DateTime.now());
      _notify();
    }
  }

  /// Builds control traffic using whichever peer belongs to the active session.
  Future<void> _sendForCurrent(ControlPacketType type) async {
    final current = _session;
    final peer = _activePeer;
    if (current == null || peer == null) {
      return;
    }
    await _sendControl(type, peer, sessionId: current.sessionId);
  }

  Future<void> _sendControl(
    ControlPacketType type,
    Peer peer, {
    required String sessionId,
    Map<String, Object?>? metadata,
  }) {
    // A manually typed IP has no guaranteed discovered device ID, so its first
    // message is un-targeted; the destination IP still limits who receives it.
    return _signaling.send(
      ControlPacket(
        type: type,
        sessionId: sessionId,
        senderId: deviceId,
        senderName: deviceName,
        targetId: peer.isManual ? null : peer.id,
        timestamp: DateTime.now(),
        metadata: metadata ??
            <String, Object?>{
              'mode': _session?.mode.wireName ?? settings.mode.wireName,
              'sampleRate': _session?.sampleRate ?? settings.sampleRate,
              'audioPort': audioPort,
              'controlPort': controlPort,
            },
      ),
      peer,
    );
  }

  /// Promotes signaling information into a current routeable peer record.
  ///
  /// The actual datagram source IP is preferred over claimed metadata, which
  /// remains correct when a phone is on a hotspot address not known in advance.
  Peer _peerFromPacket(ControlPacket packet) {
    final ipAddress = packet.sourceIp ?? '0.0.0.0';
    final known = _peerRegistry.findByIdOrIp(packet.senderId, ipAddress);
    return Peer(
      id: packet.senderId,
      name: packet.senderName,
      ipAddress: ipAddress,
      audioPort: _metadataPort(packet.metadata['audioPort'], audioPort),
      controlPort: _metadataPort(packet.metadata['controlPort'], controlPort),
      discoveryPort: known?.discoveryPort ?? discoveryPort,
      lastSeen: DateTime.now(),
      supportedModes: known?.supportedModes ??
          const <CommunicationMode>{
            CommunicationMode.pushToTalk,
            CommunicationMode.fullDuplex,
          },
      isManual: known?.isManual ?? false,
    );
  }

  Peer? get _activePeer {
    final current = _session;
    if (current == null) {
      return _selectedPeer;
    }
    return _peerRegistry.findByIdOrIp(current.remotePeerId, current.remoteIp) ??
        _selectedPeer;
  }

  /// Central failure path so audio resources and on-screen result stay aligned.
  Future<void> _failCall(String reason) async {
    await _finishCall(CallStatus.failed, reason: reason);
  }

  /// Tears down per-call timers and media, then leaves a readable final state.
  ///
  /// Closing the recorder/player here matters: otherwise microphone capture or
  /// speaker routing could survive after the UI says that the call has ended.
  Future<void> _finishCall(CallStatus status, {required String reason}) async {
    _cancelInviteTimers();
    _heartbeatTimer?.cancel();
    _durationTimer?.cancel();
    _receivingTimer?.cancel();
    _heartbeatTimer = null;
    _durationTimer = null;
    _receivingTimer = null;
    await _audioCapture.stop(onLog: _logs.info);
    await _audioPlayback.stopStream();
    await _audioRoute.endCall();
    _isSending = false;
    _isReceiving = false;
    _session = _session?.copyWith(
      status: status,
      endedAt: DateTime.now(),
      failureReason: reason,
    );
    if (status == CallStatus.failed) {
      _logs.error(reason);
    } else {
      _logs.info(reason);
    }
    _notify();
  }

  /// Stops all ringing-related scheduled work once a call answers or terminates.
  void _cancelInviteTimers() {
    _inviteTimer?.cancel();
    _callTimeoutTimer?.cancel();
    _inviteTimer = null;
    _callTimeoutTimer = null;
  }

  /// Creates a locally unique session key; it is identity, not authentication.
  String _newSessionId() =>
      '$deviceId-${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(99999)}';

  int _metadataPort(Object? value, int fallback) =>
      value is int ? value : int.tryParse('$value') ?? fallback;

  void _setError(String message) {
    _errorMessage = message;
    _logs.error(message);
    _notify();
  }

  /// Minimal input validation for the manual local IPv4 fallback.
  bool _isValidIpv4(String value) {
    final pieces = value.split('.');
    return pieces.length == 4 &&
        pieces.every((piece) {
          final number = int.tryParse(piece);
          return number != null && number >= 0 && number <= 255;
        });
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelInviteTimers();
    _heartbeatTimer?.cancel();
    _durationTimer?.cancel();
    _receivingTimer?.cancel();
    _logs.removeListener(_notify);
    _peerRegistry.removeListener(_notify);
    _peerRegistry.dispose();
    unawaited(_shutdown());
    super.dispose();
  }

  /// Completes asynchronous resource release after Flutter stops observing us.
  Future<void> _shutdown() async {
    await _audioCapture.close();
    await _audioPlayback.close();
    await _audioRoute.endCall();
    await _audioTransport.stop();
    await _signaling.stop();
    await _discovery.stop();
  }

  /// Avoids notifying Flutter after widget ownership disposed this controller.
  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }
}
