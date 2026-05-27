import 'dart:async';

import 'package:flutter/material.dart';

import 'models/call_session.dart';
import 'models/communication_mode.dart';
import 'models/debug_log_entry.dart';
import 'models/network_snapshot.dart';
import 'models/peer.dart';
import 'services/app_constants.dart';
import 'services/call_controller.dart';

/// Flutter entry point.
///
/// Native Android starts the Flutter engine, and Flutter calls this function
/// to attach the first widget tree. `ensureInitialized` makes plugin/platform
/// services ready before the controller asks for permissions or network data.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const PeerTalkApp());
}

/// Top-level visual configuration for this offline intercom application.
///
/// Notice that it creates no network objects. The root app owns theme and the
/// first screen; [CallController] below owns asynchronous protocol behavior.
class PeerTalkApp extends StatelessWidget {
  const PeerTalkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PeerTalk',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff126a60))
            .copyWith(secondary: const Color(0xffc77b20)),
        scaffoldBackgroundColor: const Color(0xfff5f7f4),
        cardTheme: const CardTheme(
          elevation: 0,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(8)),
            side: BorderSide(color: Color(0xffd9ded7)),
          ),
        ),
      ),
      home: const PeerTalkHome(),
    );
  }
}

/// Root navigation changes to ringing/call surfaces whenever a session exists.
///
/// This stateful owner constructs exactly one [CallController] for the visible
/// app lifetime. Discovery sockets and call timers therefore persist while a
/// person switches between Peers, Settings, and Logs tabs.
class PeerTalkHome extends StatefulWidget {
  const PeerTalkHome({super.key});

  @override
  State<PeerTalkHome> createState() => _PeerTalkHomeState();
}

class _PeerTalkHomeState extends State<PeerTalkHome> {
  /// UI-owned controller responsible for all networking and call state.
  late final CallController _controller;

  // TextEditingControllers retain typed text between rebuilds; they are UI
  // resources and are disposed here rather than inside networking services.
  final TextEditingController _manualIpController = TextEditingController();
  final TextEditingController _deviceNameController = TextEditingController();
  int _tabIndex = 0;
  bool _loadedDeviceName = false;

  @override
  void initState() {
    super.initState();
    _controller = CallController();
    // Initialization touches plugins and sockets asynchronously. The first
    // frame can display a startup status while this work finishes.
    unawaited(_controller.initialize());
  }

  @override
  void dispose() {
    _manualIpController.dispose();
    _deviceNameController.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // AnimatedBuilder redraws only when CallController calls notifyListeners,
    // converting asynchronous network/audio events into current screen state.
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        if (!_loadedDeviceName && _controller.deviceName.isNotEmpty) {
          _deviceNameController.text = _controller.deviceName;
          _loadedDeviceName = true;
        }
        final session = _controller.session;
        // Incoming calls replace navigation with answer/reject actions. Any
        // other session (outgoing, active, ended, failed) uses the call view.
        if (session?.status == CallStatus.incomingRinging) {
          return _IncomingCallScreen(
              controller: _controller, session: session!);
        }
        if (session != null) {
          return _CallScreen(controller: _controller, session: session);
        }
        return Scaffold(
          appBar: AppBar(
            title: const Text('PeerTalk'),
            actions: <Widget>[
              IconButton(
                tooltip: 'Refresh network',
                onPressed: _controller.refreshNetworkInfo,
                icon: const Icon(Icons.wifi_find),
              ),
              IconButton(
                tooltip: 'Announce presence',
                onPressed: _controller.broadcastNow,
                icon: const Icon(Icons.radar),
              ),
            ],
          ),
          body: SafeArea(
            // IndexedStack retains each tab's widget state while showing only
            // one; e.g. the logs list does not reconstruct unnecessarily.
            child: IndexedStack(
              index: _tabIndex,
              children: <Widget>[
                _HomeScreen(
                  controller: _controller,
                  manualIpController: _manualIpController,
                ),
                _SettingsScreen(
                  controller: _controller,
                  nameController: _deviceNameController,
                  manualIpController: _manualIpController,
                ),
                _LogsScreen(controller: _controller),
              ],
            ),
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _tabIndex,
            onDestinationSelected: (value) => setState(() => _tabIndex = value),
            destinations: const <NavigationDestination>[
              NavigationDestination(
                icon: Icon(Icons.people_alt_outlined),
                selectedIcon: Icon(Icons.people_alt),
                label: 'Peers',
              ),
              NavigationDestination(
                icon: Icon(Icons.tune),
                label: 'Settings',
              ),
              NavigationDestination(
                icon: Icon(Icons.terminal),
                label: 'Logs',
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Scrollable home surface for current LAN information and reachable phones.
///
/// Users may either rely on discovery broadcast or type an address when a
/// router/hotspot refuses to forward broadcast packets.
class _HomeScreen extends StatelessWidget {
  const _HomeScreen({
    required this.controller,
    required this.manualIpController,
  });

  final CallController controller;
  final TextEditingController manualIpController;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
      children: <Widget>[
        _HomeStatusPanel(controller: controller),
        const SizedBox(height: 12),
        _NetworkPanel(snapshot: controller.networkSnapshot),
        const SizedBox(height: 12),
        _Panel(
          title: 'Manual peer',
          icon: Icons.add_link,
          child: Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: manualIpController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'IP address',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.location_on_outlined),
                  ),
                  onSubmitted: controller.addManualPeer,
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                tooltip: 'Add peer',
                onPressed: () =>
                    controller.addManualPeer(manualIpController.text),
                icon: const Icon(Icons.add),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _Panel(
          title: 'Available peers',
          icon: Icons.phone_android,
          trailing: IconButton(
            tooltip: 'Search now',
            onPressed: controller.broadcastNow,
            icon: const Icon(Icons.refresh),
          ),
          child: controller.peers.isEmpty
              ? const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Center(child: Text('Searching for peers...')),
                )
              : Column(
                  children: <Widget>[
                    for (final peer in controller.peers) ...<Widget>[
                      _PeerRow(controller: controller, peer: peer),
                      const SizedBox(height: 8),
                    ],
                  ],
                ),
        ),
      ],
    );
  }
}

/// Compact at-a-glance display of discovery readiness and microphone access.
class _HomeStatusPanel extends StatelessWidget {
  const _HomeStatusPanel({required this.controller});

  final CallController controller;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: <Widget>[
            Icon(
              controller.initializing ? Icons.sync : Icons.wifi_tethering,
              color: colors.primary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    controller.homeStatus,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  Text(
                    controller.deviceName.isEmpty
                        ? 'PeerTalk'
                        : controller.deviceName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (!controller.hasMicrophonePermission)
              IconButton.filledTonal(
                tooltip: 'Allow microphone',
                onPressed: controller.requestPermissions,
                icon: const Icon(Icons.mic_off),
              ),
          ],
        ),
      ),
    );
  }
}

/// Presents the local addressing information used to troubleshoot two phones.
///
/// These labels are intentionally selectable: while testing, a learner can
/// compare the hotspot host address and connected device address directly.
class _NetworkPanel extends StatelessWidget {
  const _NetworkPanel({required this.snapshot});

  final NetworkSnapshot? snapshot;

  @override
  Widget build(BuildContext context) {
    final rows = snapshot?.displayRows ??
        const <(String, String)>[
          ('Local IP', 'Loading'),
          ('Wi-Fi', 'Loading'),
        ];
    return _Panel(
      title: 'Network',
      icon: Icons.router,
      child: Column(
        children: <Widget>[
          for (final row in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: <Widget>[
                  SizedBox(
                    width: 90,
                    child: Text(
                      row.$1,
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                  ),
                  Expanded(child: SelectableText(row.$2)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// One discovered/manual endpoint with a direct call affordance.
///
/// Tapping the row displays the separate control/audio ports and supported
/// mode advertisement; tapping its phone icon begins signaling immediately.
class _PeerRow extends StatelessWidget {
  const _PeerRow({required this.controller, required this.peer});

  final CallController controller;
  final Peer peer;

  @override
  Widget build(BuildContext context) {
    final selected = controller.selectedPeer?.id == peer.id;
    final modes = peer.supportedModes.map((mode) => mode.label).join(' / ');
    return Material(
      color: selected
          ? Theme.of(context).colorScheme.primaryContainer.withOpacity(0.35)
          : Colors.white,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () {
          controller.selectPeer(peer);
          showModalBottomSheet<void>(
            context: context,
            showDragHandle: true,
            builder: (context) =>
                _PeerDetailSheet(controller: controller, peer: peer),
          );
        },
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
          decoration: BoxDecoration(
            border: Border.all(color: const Color(0xffd9ded7)),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: <Widget>[
              Icon(peer.isManual ? Icons.push_pin : Icons.smartphone),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      peer.name,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      '${peer.callEndpoint}  |  '
                      '${peer.isManual ? 'Manual' : 'Online'}',
                    ),
                    Text(
                      modes,
                      style: Theme.of(context).textTheme.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              IconButton.filled(
                tooltip: 'Call ${peer.name}',
                onPressed: () => controller.callPeer(peer),
                icon: const Icon(Icons.call),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Bottom sheet that exposes peer protocol facts before making a call.
class _PeerDetailSheet extends StatelessWidget {
  const _PeerDetailSheet({required this.controller, required this.peer});

  final CallController controller;
  final Peer peer;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              peer.name,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 14),
            _DetailLine(label: 'IP address', value: peer.ipAddress),
            _DetailLine(label: 'Audio port', value: '${peer.audioPort}'),
            _DetailLine(label: 'Control port', value: '${peer.controlPort}'),
            _DetailLine(
              label: 'Modes',
              value: peer.supportedModes.map((mode) => mode.label).join(', '),
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () {
                  Navigator.of(context).pop();
                  controller.callPeer(peer);
                },
                icon: const Icon(Icons.call),
                label: const Text('Call'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Reusable aligned label/value row for technical endpoint details.
class _DetailLine extends StatelessWidget {
  const _DetailLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ),
          Expanded(child: SelectableText(value)),
        ],
      ),
    );
  }
}

/// Full-screen answer/reject surface displayed for `CALL_INVITE`.
///
/// Audio is not active while this screen is visible: only accepting crosses
/// from signaling into recorder/player setup.
class _IncomingCallScreen extends StatelessWidget {
  const _IncomingCallScreen({
    required this.controller,
    required this.session,
  });

  final CallController controller;
  final CallSession session;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        // A full-size box gives Center the complete safe screen to work with.
        // The max width keeps the call controls pleasantly grouped on tablets
        // or in landscape rather than allowing them to appear edge-aligned.
        child: SizedBox.expand(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    CircleAvatar(
                      radius: 48,
                      backgroundColor:
                          Theme.of(context).colorScheme.primaryContainer,
                      child: const Icon(Icons.call_received, size: 44),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      session.remoteName,
                      style:
                          Theme.of(context).textTheme.headlineSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                    ),
                    const SizedBox(height: 8),
                    Text('${session.mode.label} call'),
                    const SizedBox(height: 52),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: <Widget>[
                        _CallAction(
                          tooltip: 'Reject',
                          color: Theme.of(context).colorScheme.error,
                          icon: Icons.call_end,
                          onPressed: controller.rejectIncomingCall,
                        ),
                        const SizedBox(width: 40),
                        _CallAction(
                          tooltip: 'Accept',
                          color: const Color(0xff118449),
                          icon: Icons.call,
                          onPressed: controller.acceptIncomingCall,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Outgoing-ringing, connected, ended, and failed call presentation.
///
/// A single screen follows one immutable [CallSession] through its lifecycle;
/// the controller drives transitions when UDP control packets or user actions
/// arrive. The ended state stays here long enough to read failure information.
class _CallScreen extends StatelessWidget {
  const _CallScreen({required this.controller, required this.session});

  final CallController controller;
  final CallSession session;

  @override
  Widget build(BuildContext context) {
    final finished = session.status.isTerminal;
    return Scaffold(
      appBar: AppBar(title: Text(session.remoteName)),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Call content is centered in a bounded column. Retaining the full
            // available height is important because Spacer widgets arrange the
            // avatar and action controls vertically.
            final contentWidth =
                constraints.maxWidth > 480 ? 480.0 : constraints.maxWidth;
            return Center(
              child: SizedBox(
                width: contentWidth,
                height: constraints.maxHeight,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
                  child: Column(
                    children: <Widget>[
                      const Spacer(),
                      CircleAvatar(
                        radius: 48,
                        backgroundColor:
                            Theme.of(context).colorScheme.primaryContainer,
                        child: Icon(
                          session.status == CallStatus.outgoingRinging
                              ? Icons.call_made
                              : Icons.person,
                          size: 44,
                        ),
                      ),
                      const SizedBox(height: 18),
                      Text(
                        session.remoteName,
                        style:
                            Theme.of(context).textTheme.headlineSmall?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                      ),
                      const SizedBox(height: 8),
                      Text(session.status.label),
                      const SizedBox(height: 4),
                      Text(
                        '${session.mode.label}  |  ${_duration(session.duration)}',
                      ),
                      const SizedBox(height: 28),
                      if (session.status.isActive)
                        _QualityPanel(controller: controller, session: session),
                      const Spacer(),
                      if (session.status == CallStatus.connected &&
                          session.mode == CommunicationMode.pushToTalk)
                        _PushToTalkButton(controller: controller),
                      if (session.status == CallStatus.connected) ...<Widget>[
                        const SizedBox(height: 20),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: <Widget>[
                            _CallAction(
                              tooltip: controller.isMuted ? 'Unmute' : 'Mute',
                              color: controller.isMuted
                                  ? Theme.of(context).colorScheme.secondary
                                  : const Color(0xff5b6863),
                              icon: controller.isMuted
                                  ? Icons.mic_off
                                  : Icons.mic,
                              onPressed: controller.toggleMute,
                            ),
                            const SizedBox(width: 24),
                            _CallAction(
                              tooltip: controller.speakerphoneEnabled
                                  ? 'Disable speaker'
                                  : 'Enable speaker',
                              color: controller.speakerphoneEnabled
                                  ? Theme.of(context).colorScheme.primary
                                  : const Color(0xff5b6863),
                              icon: controller.speakerphoneEnabled
                                  ? Icons.volume_up
                                  : Icons.volume_off,
                              onPressed: controller.toggleSpeakerphone,
                            ),
                            const SizedBox(width: 24),
                            _CallAction(
                              tooltip: 'End call',
                              color: Theme.of(context).colorScheme.error,
                              icon: Icons.call_end,
                              onPressed: controller.endCall,
                            ),
                          ],
                        ),
                      ] else if (finished) ...<Widget>[
                        if (session.failureReason != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 20),
                            child: Text(session.failureReason!),
                          ),
                        FilledButton.icon(
                          onPressed: controller.dismissFinishedCall,
                          icon: const Icon(Icons.done),
                          label: const Text('Done'),
                        ),
                      ] else
                        _CallAction(
                          tooltip: 'Cancel call',
                          color: Theme.of(context).colorScheme.error,
                          icon: Icons.call_end,
                          onPressed: controller.endCall,
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  String _duration(Duration duration) {
    // Duration is kept deliberately conversational rather than showing dates.
    final minutes = duration.inMinutes.toString().padLeft(2, '0');
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}

/// Read-only current media-health summary during an accepted call.
class _QualityPanel extends StatelessWidget {
  const _QualityPanel({required this.controller, required this.session});

  final CallController controller;
  final CallSession session;

  @override
  Widget build(BuildContext context) {
    final loss = controller.statistics.packetLossPercent.toStringAsFixed(1);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: <Widget>[
            _Metric(
              icon: controller.isReceiving ? Icons.download : Icons.graphic_eq,
              value: controller.isReceiving ? 'Receiving' : 'Listening',
            ),
            _Metric(icon: Icons.network_check, value: '$loss% loss'),
            _Metric(
                icon: Icons.speed, value: '${session.sampleRate ~/ 1000} kHz'),
          ],
        ),
      ),
    );
  }
}

/// One equally sized value in the quality row.
class _Metric extends StatelessWidget {
  const _Metric({required this.icon, required this.value});

  final IconData icon;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: <Widget>[
          Icon(icon, size: 21),
          const SizedBox(height: 4),
          Text(
            value,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

/// Touch-and-hold microphone control retained as the low-complexity fallback.
///
/// `onTapDown` starts capture; release or touch cancellation stops it. The
/// cancellation handler matters when a finger slides away or Android
/// interrupts a gesture, otherwise a transmitter could stay open accidentally.
class _PushToTalkButton extends StatelessWidget {
  const _PushToTalkButton({required this.controller});

  final CallController controller;

  @override
  Widget build(BuildContext context) {
    final enabled = !controller.isMuted;
    final active = controller.isSending;
    final color = active
        ? const Color(0xffb24d1a)
        : enabled
            ? Theme.of(context).colorScheme.primary
            : Colors.grey;
    return GestureDetector(
      onTapDown: enabled ? (_) => controller.startTalking() : null,
      onTapUp: enabled ? (_) => controller.stopTalking() : null,
      onTapCancel: enabled ? controller.stopTalking : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        width: 148,
        height: 148,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        child: const Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(Icons.mic, color: Colors.white, size: 38),
            SizedBox(height: 6),
            Text(
              'HOLD TO TALK',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                letterSpacing: 0,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Local configuration for how this phone advertises and participates in calls.
///
/// Mode and PCM settings affect newly created calls because two endpoints must
/// agree before exchanging audio; modifying a running stream would break that
/// agreement.
class _SettingsScreen extends StatelessWidget {
  const _SettingsScreen({
    required this.controller,
    required this.nameController,
    required this.manualIpController,
  });

  final CallController controller;
  final TextEditingController nameController;
  final TextEditingController manualIpController;

  @override
  Widget build(BuildContext context) {
    final settings = controller.settings;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        _Panel(
          title: 'Identity',
          icon: Icons.badge_outlined,
          child: Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: nameController,
                  decoration: const InputDecoration(
                    labelText: 'Device name',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: controller.updateDeviceName,
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                tooltip: 'Save name',
                onPressed: () =>
                    controller.updateDeviceName(nameController.text),
                icon: const Icon(Icons.save),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _Panel(
          title: 'Manual peer',
          icon: Icons.add_link,
          child: Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: manualIpController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'IP address',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: controller.addManualPeer,
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                tooltip: 'Add peer',
                onPressed: () =>
                    controller.addManualPeer(manualIpController.text),
                icon: const Icon(Icons.add),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _Panel(
          title: 'Communication',
          icon: Icons.call,
          child: Column(
            children: <Widget>[
              SegmentedButton<CommunicationMode>(
                segments: const <ButtonSegment<CommunicationMode>>[
                  ButtonSegment<CommunicationMode>(
                    value: CommunicationMode.pushToTalk,
                    icon: Icon(Icons.touch_app),
                    label: Text('PTT'),
                  ),
                  ButtonSegment<CommunicationMode>(
                    value: CommunicationMode.fullDuplex,
                    icon: Icon(Icons.phone_in_talk),
                    label: Text('Duplex'),
                  ),
                ],
                selected: <CommunicationMode>{settings.mode},
                onSelectionChanged: (selection) =>
                    controller.updateMode(selection.first),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Speakerphone'),
                secondary: const Icon(Icons.volume_up),
                value: settings.speakerphoneEnabled,
                onChanged: (_) => controller.toggleSpeakerphone(),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _Panel(
          title: 'Audio and network',
          icon: Icons.tune,
          child: Column(
            children: <Widget>[
              _SettingSlider(
                label: 'Discovery interval',
                value: settings.discoveryIntervalSeconds.toDouble(),
                min: 1,
                max: 5,
                divisions: 4,
                suffix: 's',
                onChanged: (value) =>
                    controller.updateDiscoveryInterval(value.round()),
              ),
              _SettingSlider(
                label: 'Jitter buffer',
                value: settings.jitterBufferMs.toDouble(),
                min: 20,
                max: 180,
                divisions: 8,
                suffix: 'ms',
                onChanged: (value) =>
                    controller.updateJitterBuffer(value.round()),
              ),
              DropdownButtonFormField<int>(
                value: settings.sampleRate,
                decoration: const InputDecoration(
                  labelText: 'Sample rate',
                  prefixIcon: Icon(Icons.graphic_eq),
                ),
                items: <DropdownMenuItem<int>>[
                  for (final rate in supportedSampleRates)
                    DropdownMenuItem<int>(
                      value: rate,
                      child: Text('${rate ~/ 1000} kHz'),
                    ),
                ],
                onChanged: (value) {
                  if (value != null) {
                    controller.updateSampleRate(value);
                  }
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _Panel(
          title: 'Diagnostics',
          icon: Icons.bug_report_outlined,
          child: SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Debug logs'),
            secondary: const Icon(Icons.terminal),
            value: settings.debugLogsEnabled,
            onChanged: controller.updateDebugLogs,
          ),
        ),
      ],
    );
  }
}

/// Standard presentation for bounded integer tuning values.
///
/// Sliders make latency/reliability values easy to explore on physical phones:
/// discovery interval affects peer freshness and jitter delay affects playout.
class _SettingSlider extends StatelessWidget {
  const _SettingSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.suffix,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String suffix;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(child: Text(label)),
            Text('${value.round()} $suffix'),
          ],
        ),
        Slider(
          value: value,
          min: min,
          max: max,
          divisions: divisions,
          onChanged: onChanged,
        ),
      ],
    );
  }
}

/// In-app protocol console for physical-device troubleshooting and learning.
///
/// Events let a learner follow discovery, invitation, heartbeat, and media
/// traffic without attaching a computer debugger to both Android phones.
class _LogsScreen extends StatelessWidget {
  const _LogsScreen({required this.controller});

  final CallController controller;

  @override
  Widget build(BuildContext context) {
    final entries = controller.logs.reversed.toList(growable: false);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  const Icon(Icons.terminal, size: 22),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Debug logs',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Clear logs',
                    onPressed: controller.clearLogs,
                    icon: const Icon(Icons.delete_sweep),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // The panel is already inside the Scaffold body, SafeArea, and
              // bottom navigation layout. Expanded uses only the remaining
              // room here; deriving a height from the full device screen
              // double-counts those occupied areas and causes pixel overflow.
              Expanded(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color(0xff111512),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: entries.length,
                    itemBuilder: (context, index) {
                      final entry = entries[index];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 5),
                        child: Text(
                          '${entry.formattedTime}  ${entry.message}',
                          style: TextStyle(
                            color: _logColor(entry.level),
                            fontFamily: 'monospace',
                            fontSize: 12,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Color _logColor(DebugLogLevel level) {
    // Level colors visually separate ordinary lifecycle messages, recoverable
    // warnings, failures, and high-frequency network packet observations.
    switch (level) {
      case DebugLogLevel.info:
        return const Color(0xffd8e5d7);
      case DebugLogLevel.warning:
        return const Color(0xffffcf76);
      case DebugLogLevel.error:
        return const Color(0xffffa0a0);
      case DebugLogLevel.packet:
        return const Color(0xff9cd4ff);
    }
  }
}

/// Consistent framed grouping used by small settings/home content sections.
class _Panel extends StatelessWidget {
  const _Panel({
    required this.title,
    required this.icon,
    required this.child,
    this.trailing,
  });

  final String title;
  final IconData icon;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(icon, size: 22),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                ),
                if (trailing != null) trailing!,
              ],
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

/// Circular icon command used for call acceptance, mute, route, and hang-up.
class _CallAction extends StatelessWidget {
  const _CallAction({
    required this.tooltip,
    required this.color,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final Color color;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: IconButton.filled(
        onPressed: onPressed,
        style: IconButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
          fixedSize: const Size(58, 58),
        ),
        icon: Icon(icon, size: 27),
      ),
    );
  }
}
