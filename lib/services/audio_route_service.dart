import 'package:flutter/services.dart';

import 'debug_log_service.dart';

/// Small Android bridge for call-specific speaker routing.
///
/// Flutter Sound handles sample capture/playback, but its Dart API does not
/// expose Android's speakerphone communication mode in the pinned dependency.
class AudioRouteService {
  AudioRouteService({required DebugLogService logs}) : _logs = logs;

  /// MethodChannel names must match Kotlin exactly; it is the address Flutter
  /// uses when asking platform-specific Android code to perform an action.
  static const _channel = MethodChannel('com.peertalk.peer_talk/audio_route');
  final DebugLogService _logs;

  /// Switches Android into communication routing while a call is active.
  Future<void> beginCall({required bool speakerphone}) async {
    try {
      await _channel.invokeMethod<void>('beginCall', <String, Object?>{
        'speakerphone': speakerphone,
      });
    } on PlatformException catch (error) {
      _logs.warning('Could not configure Android call audio: $error');
    }
  }

  /// Routes voice to loud speaker or normal device route during a live call.
  Future<void> setSpeakerphone(bool enabled) async {
    try {
      await _channel.invokeMethod<void>('setSpeakerphone', <String, Object?>{
        'enabled': enabled,
      });
    } on PlatformException catch (error) {
      _logs.warning('Could not switch speakerphone: $error');
    }
  }

  /// Restores ordinary audio behavior after call media has ended.
  Future<void> endCall() async {
    try {
      await _channel.invokeMethod<void>('endCall');
    } on PlatformException catch (error) {
      _logs.warning('Could not reset Android call audio: $error');
    }
  }
}
