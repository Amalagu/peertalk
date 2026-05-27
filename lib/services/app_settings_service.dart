import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/communication_mode.dart';
import 'app_constants.dart';

/// Persists user-facing tuning choices between app launches.
///
/// Settings affect future calls; changing audio format during an active call
/// would leave the two peers interpreting PCM with different parameters.
class AppSettingsService extends ChangeNotifier {
  // SharedPreferences is a simple Android key/value store, suitable for small
  // user preferences. These names are internal storage keys, not wire protocol
  // fields; each phone may independently choose its local preferences.
  static const _modeKey = 'mode';
  static const _discoveryIntervalKey = 'discoveryIntervalSeconds';
  static const _sampleRateKey = 'audioSampleRate';
  static const _jitterBufferKey = 'jitterBufferMs';
  static const _debugLogsKey = 'debugLogs';
  static const _speakerphoneKey = 'speakerphone';
  static const _deviceNameKey = 'deviceName';

  /// Cached storage handle; it is available after [load] during app startup.
  SharedPreferences? _preferences;

  // These public values are the currently active preferences exposed to
  // widgets/controller. Defaults let the first render work before disk reads.
  CommunicationMode mode = CommunicationMode.pushToTalk;
  int discoveryIntervalSeconds = defaultDiscoveryIntervalSeconds;
  int sampleRate = audioSampleRate;
  int jitterBufferMs = defaultJitterBufferMs;
  bool debugLogsEnabled = true;
  bool speakerphoneEnabled = true;
  String deviceName = '';

  /// Loads persisted preferences and selects a generated name on first launch.
  ///
  /// `notifyListeners` is Flutter's signal that any screen reading these
  /// values should rebuild. Settings need no server because they describe only
  /// this phone's behavior.
  Future<void> load({required String defaultDeviceName}) async {
    _preferences = await SharedPreferences.getInstance();
    mode = CommunicationModeDisplay.fromWireName(
      _preferences?.getString(_modeKey),
    );
    discoveryIntervalSeconds = _preferences?.getInt(_discoveryIntervalKey) ??
        defaultDiscoveryIntervalSeconds;
    sampleRate = _preferences?.getInt(_sampleRateKey) ?? audioSampleRate;
    jitterBufferMs =
        _preferences?.getInt(_jitterBufferKey) ?? defaultJitterBufferMs;
    debugLogsEnabled = _preferences?.getBool(_debugLogsKey) ?? true;
    speakerphoneEnabled = _preferences?.getBool(_speakerphoneKey) ?? true;
    deviceName = _preferences?.getString(_deviceNameKey) ?? defaultDeviceName;
    notifyListeners();
  }

  /// Stores the preferred mode for a subsequent outgoing call.
  ///
  /// A live session keeps its already negotiated mode so the two phones do not
  /// reinterpret audio midway through a conversation.
  Future<void> setMode(CommunicationMode value) async {
    mode = value;
    await _preferences?.setString(_modeKey, value.wireName);
    notifyListeners();
  }

  /// Controls how often this phone broadcasts "I am here" on the LAN.
  Future<void> setDiscoveryInterval(int value) async {
    discoveryIntervalSeconds = value;
    await _preferences?.setInt(_discoveryIntervalKey, value);
    notifyListeners();
  }

  /// Selects the PCM clock rate offered when a new call starts.
  ///
  /// Only known rates are admitted; otherwise two record/playback pipelines
  /// could disagree and voice would sound distorted or fail.
  Future<void> setSampleRate(int value) async {
    if (!supportedSampleRates.contains(value)) {
      return;
    }
    sampleRate = value;
    await _preferences?.setInt(_sampleRateKey, value);
    notifyListeners();
  }

  /// Sets the short receiver delay used to absorb irregular UDP arrival times.
  Future<void> setJitterBuffer(int value) async {
    jitterBufferMs = value;
    await _preferences?.setInt(_jitterBufferKey, value);
    notifyListeners();
  }

  /// Changes collection of routine log messages; serious errors remain logged.
  Future<void> setDebugLogsEnabled(bool value) async {
    debugLogsEnabled = value;
    await _preferences?.setBool(_debugLogsKey, value);
    notifyListeners();
  }

  /// Remembers whether call audio should default to Android's loud speaker.
  Future<void> setSpeakerphoneEnabled(bool value) async {
    speakerphoneEnabled = value;
    await _preferences?.setBool(_speakerphoneKey, value);
    notifyListeners();
  }

  /// Stores the human-readable identity announced to nearby PeerTalk devices.
  Future<void> setDeviceName(String value) async {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return;
    }
    deviceName = trimmed;
    await _preferences?.setString(_deviceNameKey, trimmed);
    notifyListeners();
  }
}
