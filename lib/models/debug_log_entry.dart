/// Visual importance categories used by the on-screen diagnostic console.
///
/// In networking code, logs are especially useful because two separate
/// devices are cooperating: when audio is silent, packet logs help establish
/// whether the issue is capture, network transport, or playback.
enum DebugLogLevel { info, warning, error, packet }

/// One immutable line in the in-app log panel.
///
/// `DateTime.now()` is captured at construction time so the timestamp reports
/// when an event occurred, not when Flutter happens to redraw the log widget.
class DebugLogEntry {
  DebugLogEntry({
    required this.message,
    required this.level,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  final String message;
  final DebugLogLevel level;
  final DateTime timestamp;

  /// A compact local-time timestamp including milliseconds, which matters when
  /// inspecting interactive audio traffic and rapidly repeated UDP events.
  String get formattedTime {
    String two(int value) => value.toString().padLeft(2, '0');
    String three(int value) => value.toString().padLeft(3, '0');
    return '${two(timestamp.hour)}:${two(timestamp.minute)}:'
        '${two(timestamp.second)}.${three(timestamp.millisecond)}';
  }
}
