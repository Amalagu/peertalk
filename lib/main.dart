import 'package:flutter/material.dart';

import 'models/debug_log_entry.dart';
import 'models/network_snapshot.dart';
import 'models/peer.dart';
import 'services/call_controller.dart';

/// Flutter application entry point.
///
/// `ensureInitialized` makes platform-channel services available before any
/// audio or permission plugin is used. The app itself is still entirely local:
/// plugin channels speak from Dart to Android inside this phone, not to cloud
/// services.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const PeerTalkApp());
}

/// Top-level Flutter configuration: theme and first screen only.
///
/// Networking/audio state intentionally lives below in [CallController] rather
/// than in `MaterialApp`, so visual configuration stays independent of the
/// walkie-talkie mechanics.
class PeerTalkApp extends StatelessWidget {
  const PeerTalkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PeerTalk',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff136f63),
        ).copyWith(secondary: const Color(0xffd08b23)),
        scaffoldBackgroundColor: const Color(0xfff7f8f5),
      ),
      home: const PeerTalkHome(),
    );
  }
}

/// The one-screen MVP user experience.
class PeerTalkHome extends StatefulWidget {
  const PeerTalkHome({super.key});

  @override
  State<PeerTalkHome> createState() => _PeerTalkHomeState();
}

class _PeerTalkHomeState extends State<PeerTalkHome> {
  /// The controller survives widget rebuilds and owns native/service lifetimes.
  late final CallController _controller;

  /// A Flutter editing controller preserves manually entered IP address text.
  final TextEditingController _manualIpController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _controller = CallController();

    // Startup is asynchronous (permission dialogs and socket binding) but
    // initState itself is synchronous; the controller notifies the UI as each
    // startup state becomes available.
    _controller.initialize();
  }

  @override
  void dispose() {
    _manualIpController.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // `AnimatedBuilder` listens to ChangeNotifier updates. Whenever services
    // alter visible state, this widget subtree redraws with current values.
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(
            title: const Text('PeerTalk'),
            actions: <Widget>[
              IconButton(
                tooltip: 'Refresh network',
                // Useful after joining a different hotspot while app is open.
                onPressed: _controller.refreshNetworkInfo,
                icon: const Icon(Icons.wifi_find),
              ),
              IconButton(
                tooltip: 'Broadcast discovery',
                // Manually repeats the LAN-wide "hello" advertisement.
                onPressed: _controller.broadcastNow,
                icon: const Icon(Icons.radar),
              ),
            ],
          ),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: <Widget>[
                _StatusPanel(controller: _controller),
                const SizedBox(height: 12),
                _NetworkPanel(snapshot: _controller.networkSnapshot),
                const SizedBox(height: 12),
                _PeerPanel(
                  controller: _controller,
                  manualIpController: _manualIpController,
                ),
                const SizedBox(height: 16),
                _TalkPanel(controller: _controller),
                const SizedBox(height: 16),
                _LogPanel(controller: _controller),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Presents controller status as immediate feedback while networking/audio
/// operations occur in the background.
class _StatusPanel extends StatelessWidget {
  const _StatusPanel({required this.controller});

  final CallController controller;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = _statusColor(controller.status, scheme);

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.35)),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              CircleAvatar(
                radius: 18,
                backgroundColor: color.withOpacity(0.12),
                child: Icon(_statusIcon(controller.status), color: color),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  controller.status.label,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ),
              if (controller.status == CallStatus.permissionNeeded)
                FilledButton.icon(
                  onPressed: controller.requestPermissions,
                  icon: const Icon(Icons.mic),
                  label: const Text('Allow'),
                ),
            ],
          ),
          if (controller.errorMessage != null) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              controller.errorMessage!,
              style: TextStyle(color: scheme.error),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              _InfoChip(
                icon: Icons.mic,
                label: controller.hasMicrophonePermission
                    ? 'Mic allowed'
                    : 'Mic blocked',
              ),
              _InfoChip(
                icon: Icons.wifi,
                label: controller.hasNetworkInfoPermission
                    ? 'Wi-Fi info allowed'
                    : 'Wi-Fi info limited',
              ),
              const _InfoChip(
                icon: Icons.speaker,
                label: 'PCM16 16 kHz',
              ),
            ],
          ),
        ],
      ),
    );
  }

  Color _statusColor(CallStatus status, ColorScheme scheme) {
    switch (status) {
      case CallStatus.error:
      case CallStatus.permissionNeeded:
        return scheme.error;
      case CallStatus.sendingAudio:
        return const Color(0xffb24d1a);
      case CallStatus.receivingAudio:
        return const Color(0xff1a6fb2);
      case CallStatus.connected:
      case CallStatus.peerFound:
        return const Color(0xff136f63);
      case CallStatus.starting:
      case CallStatus.searching:
        return scheme.secondary;
    }
  }

  IconData _statusIcon(CallStatus status) {
    switch (status) {
      case CallStatus.error:
        return Icons.error_outline;
      case CallStatus.permissionNeeded:
        return Icons.lock_open;
      case CallStatus.searching:
        return Icons.radar;
      case CallStatus.peerFound:
        return Icons.person_search;
      case CallStatus.connected:
        return Icons.link;
      case CallStatus.sendingAudio:
        return Icons.upload;
      case CallStatus.receivingAudio:
        return Icons.download;
      case CallStatus.starting:
        return Icons.sync;
    }
  }
}

/// Displays addressing facts needed to confirm both phones share one LAN.
///
/// This panel is educationally useful during testing: two addresses with the
/// same subnet portion (for example `192.168.43.x`) normally can reach each
/// other directly without the internet.
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

    return _Section(
      title: 'Network',
      icon: Icons.router,
      child: Column(
        children: <Widget>[
          for (final row in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                children: <Widget>[
                  SizedBox(
                    width: 90,
                    child: Text(
                      row.$1,
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                  ),
                  Expanded(
                    child: SelectableText(
                      row.$2,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Displays automatic discovery results and the essential manual-IP fallback.
class _PeerPanel extends StatelessWidget {
  const _PeerPanel({
    required this.controller,
    required this.manualIpController,
  });

  final CallController controller;
  final TextEditingController manualIpController;

  @override
  Widget build(BuildContext context) {
    return _Section(
      title: 'Peers',
      icon: Icons.people_alt,
      trailing: IconButton(
        tooltip: 'Search again',
        onPressed: controller.startDiscovery,
        icon: const Icon(Icons.refresh),
      ),
      child: Column(
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: manualIpController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: 'Manual IP',
                    prefixIcon: Icon(Icons.edit_location_alt),
                  ),
                  // Keyboard submission and button press use the same route,
                  // which creates a Peer destination without discovery.
                  onSubmitted: controller.connectManual,
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: () => controller.connectManual(
                  manualIpController.text,
                ),
                icon: const Icon(Icons.add_link),
                label: const Text('Connect'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (controller.peers.isEmpty)
            const Align(
              alignment: Alignment.centerLeft,
              child: Text('No peers yet'),
            )
          else
            for (final peer in controller.peers) ...<Widget>[
              _PeerTile(
                peer: peer,
                selected: _isSelected(controller.selectedPeer, peer),
                onTap: () => controller.selectPeer(peer),
              ),
              const SizedBox(height: 8),
            ],
        ],
      ),
    );
  }

  bool _isSelected(Peer? selected, Peer peer) {
    return selected?.id == peer.id || selected?.ip == peer.ip;
  }
}

/// One selectable destination row. A peer is selected before voice traffic is
/// sent so the application never broadcasts microphone audio.
class _PeerTile extends StatelessWidget {
  const _PeerTile({
    required this.peer,
    required this.selected,
    required this.onTap,
  });

  final Peer peer;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: selected ? scheme.primary.withOpacity(0.08) : Colors.white,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected ? scheme.primary : const Color(0xffd9ded7),
            ),
          ),
          padding: const EdgeInsets.all(12),
          child: Row(
            children: <Widget>[
              Icon(
                peer.isManual ? Icons.push_pin : Icons.phone_android,
                color: selected ? scheme.primary : Colors.black54,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      peer.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 2),
                    Text(peer.endpoint),
                  ],
                ),
              ),
              if (selected) Icon(Icons.check_circle, color: scheme.primary),
            ],
          ),
        ),
      ),
    );
  }
}

/// Push-to-talk control: gesture lifecycle directly maps to audio lifecycle.
class _TalkPanel extends StatelessWidget {
  const _TalkPanel({required this.controller});

  final CallController controller;

  @override
  Widget build(BuildContext context) {
    final canTalk =
        controller.selectedPeer != null && controller.hasMicrophonePermission;
    final active = controller.isSending;
    final scheme = Theme.of(context).colorScheme;
    final color = active
        ? const Color(0xffb24d1a)
        : canTalk
            ? scheme.primary
            : Colors.grey.shade500;

    return Column(
      children: <Widget>[
        GestureDetector(
          // Press starts microphone capture; release or cancellation stops it.
          // `onTapCancel` handles a finger sliding away or interrupted touch,
          // preventing the microphone from remaining active unintentionally.
          onTapDown: canTalk ? (_) => controller.startTalking() : null,
          onTapUp: canTalk ? (_) => controller.stopTalking() : null,
          onTapCancel: canTalk ? controller.stopTalking : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: active ? 190 : 176,
            height: active ? 190 : 176,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              boxShadow: <BoxShadow>[
                BoxShadow(
                  blurRadius: active ? 26 : 14,
                  spreadRadius: active ? 3 : 0,
                  offset: const Offset(0, 10),
                  color: color.withOpacity(0.28),
                ),
              ],
            ),
            alignment: Alignment.center,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Icon(
                  active ? Icons.mic : Icons.mic_none,
                  color: Colors.white,
                  size: 42,
                ),
                const SizedBox(height: 8),
                const Text(
                  'HOLD TO TALK',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          controller.selectedPeer == null
              ? 'No peer selected'
              : controller.selectedPeer!.endpoint,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

/// In-app observability for a two-device system.
///
/// A log panel is especially valuable when learning networking: it separates
/// "peer not found", "bytes were sent", and "bytes were received" problems
/// without requiring Android Studio logcat during every physical-device test.
class _LogPanel extends StatelessWidget {
  const _LogPanel({required this.controller});

  final CallController controller;

  @override
  Widget build(BuildContext context) {
    // Newest events are shown first so changes during a test are immediately
    // visible without scrolling a growing console.
    final reversedLogs = controller.logs.reversed.toList(growable: false);
    return _Section(
      title: 'Logs',
      icon: Icons.terminal,
      trailing: IconButton(
        tooltip: 'Clear logs',
        onPressed: controller.clearLogs,
        icon: const Icon(Icons.delete_sweep),
      ),
      child: SizedBox(
        height: 220,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xff101411),
            borderRadius: BorderRadius.circular(8),
          ),
          child: ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: reversedLogs.length,
            itemBuilder: (context, index) {
              final log = reversedLogs[index];
              return Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  '${log.formattedTime}  ${log.message}',
                  style: TextStyle(
                    color: _logColor(log.level),
                    fontFamily: 'monospace',
                    fontSize: 12,
                    height: 1.25,
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Color _logColor(DebugLogLevel level) {
    switch (level) {
      case DebugLogLevel.error:
        return const Color(0xffff9e9e);
      case DebugLogLevel.warning:
        return const Color(0xffffd078);
      case DebugLogLevel.packet:
        return const Color(0xff9fd6ff);
      case DebugLogLevel.info:
        return const Color(0xffd7e3d7);
    }
  }
}

/// Consistent visual frame for independent dashboard sections.
class _Section extends StatelessWidget {
  const _Section({
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
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xffd9ded7)),
      ),
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
                        fontWeight: FontWeight.w800,
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
    );
  }
}

/// Compact capability/format indicator used in the status panel.
class _InfoChip extends StatelessWidget {
  const _InfoChip({
    required this.icon,
    required this.label,
  });

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: Icon(icon, size: 18),
      label: Text(label),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
    );
  }
}
