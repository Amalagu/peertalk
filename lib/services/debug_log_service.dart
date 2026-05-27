import 'package:flutter/foundation.dart';

import '../models/debug_log_entry.dart';

/// Keeps diagnostic events independent of call state and UI widgets.
///
/// Packet-level visibility is important for physical-phone testing, but users
/// can disable collection when they prefer a quieter screen during calls.
class DebugLogService extends ChangeNotifier {
  /// Logs are kept only in memory. They vanish on app close and never leave the
  /// phone, which is appropriate for a local diagnostic console.
  final List<DebugLogEntry> _entries = <DebugLogEntry>[];
  bool _enabled = true;

  /// An unmodifiable view prevents widgets from accidentally altering history.
  List<DebugLogEntry> get entries => List<DebugLogEntry>.unmodifiable(_entries);
  bool get enabled => _enabled;

  /// Routine diagnostics can be disabled without suppressing actual failures.
  void setEnabled(bool enabled) {
    _enabled = enabled;
    notifyListeners();
  }

  // Convenience names allow callers to express the meaning of an event while
  // this service owns timestamping, coloring, limiting, and screen rebuilds.
  void info(String message) => _write(message, DebugLogLevel.info);
  void warning(String message) => _write(message, DebugLogLevel.warning);
  void error(String message) =>
      _write(message, DebugLogLevel.error, always: true);
  void packet(String message) => _write(message, DebugLogLevel.packet);

  /// Removes visible history but does not change whether future events log.
  void clear() {
    _entries.clear();
    notifyListeners();
  }

  void _write(
    String message,
    DebugLogLevel level, {
    bool always = false,
  }) {
    if ((!_enabled && !always) || message.isEmpty) {
      return;
    }
    _entries.add(DebugLogEntry(message: message, level: level));
    // A bounded list protects memory and keeps the ListView responsive during
    // long calls, where audio and heartbeat activity can produce many events.
    if (_entries.length > 300) {
      _entries.removeRange(0, _entries.length - 300);
    }
    notifyListeners();
  }
}
