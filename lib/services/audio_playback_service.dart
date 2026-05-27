import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter_sound/flutter_sound.dart';

import 'app_constants.dart';

/// Turns received PCM byte packets back into audible speaker output.
///
/// Network delivery timing is uneven: two UDP packets might arrive together or
/// a packet might be a few milliseconds late. A tiny queue here is a "jitter
/// buffer": it trades a small startup delay for smoother playback.
class AudioPlaybackService {
  /// Native audio-output plugin endpoint.
  final FlutterSoundPlayer _player = FlutterSoundPlayer();

  /// FIFO means first packet queued is the first packet fed to the speaker.
  final Queue<Uint8List> _jitterBuffer = Queue<Uint8List>();

  /// Holds the first packet briefly so a small group can drain smoothly.
  Timer? _drainTimer;
  bool _isOpen = false;
  bool _isPlaying = false;

  /// Prepares a live player stream at the same format used for capture.
  ///
  /// `interleaved` is relevant when PCM has multiple channels; mono still sets
  /// it explicitly so the data layout agreement is visible in code.
  Future<void> open({void Function(String message)? onLog}) async {
    if (_isPlaying) {
      return;
    }
    if (!_isOpen) {
      await _player.openPlayer();
      _isOpen = true;
    }

    await _player.startPlayerFromStream(
      codec: Codec.pcm16,
      interleaved: true,
      numChannels: audioChannels,
      sampleRate: audioSampleRate,
      bufferSize: audioRecorderBufferSize,
    );
    _isPlaying = true;
    onLog?.call('Speaker playback stream ready');
  }

  /// Adds valid received audio to the short smoothing queue.
  void enqueue(Uint8List pcm) {
    if (!_isPlaying || pcm.isEmpty) {
      return;
    }

    _jitterBuffer.add(pcm);

    // Only the first recently-arrived packet creates a timer; packets arriving
    // during the wait join the same batch rather than extending latency.
    _drainTimer ??= Timer(const Duration(milliseconds: 60), _drain);
  }

  /// Stops output and discards any queued speech on application shutdown.
  Future<void> close() async {
    _drainTimer?.cancel();
    _drainTimer = null;
    _jitterBuffer.clear();

    if (_isPlaying) {
      await _player.stopPlayer();
      _isPlaying = false;
    }
    if (_isOpen) {
      await _player.closePlayer();
      _isOpen = false;
    }
  }

  /// Feeds queued PCM in arrival order to Flutter Sound's live byte sink.
  ///
  /// Version 1 does not reorder using packet sequence numbers; the queue only
  /// smooths timing. Reordering/loss concealment is a sensible later feature.
  void _drain() {
    _drainTimer = null;
    while (_jitterBuffer.isNotEmpty) {
      _player.uint8ListSink?.add(_jitterBuffer.removeFirst());
    }
  }
}
