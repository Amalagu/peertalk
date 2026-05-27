import 'dart:async';
import 'dart:collection';

import 'package:flutter_sound/flutter_sound.dart';

import '../models/audio_packet.dart';
import 'app_constants.dart';
import 'debug_log_service.dart';

/// Reorders and delays received voice packets slightly before speaker output.
///
/// UDP can deliver packets in uneven bursts. The sequence-keyed buffer waits a
/// configurable number of milliseconds, then feeds packets to Flutter Sound in
/// ascending order. Packets arriving after already-played audio are dropped.
class AudioPlaybackService {
  AudioPlaybackService({required DebugLogService logs}) : _logs = logs;

  final DebugLogService _logs;

  /// Plugin wrapper around Android's output audio track.
  final FlutterSoundPlayer _player = FlutterSoundPlayer();

  /// Sorted maps expose the smallest sequence number first even if packet 12
  /// arrives before packet 11. A normal insertion-order map cannot do this.
  final SplayTreeMap<int, _BufferedAudio> _buffer =
      SplayTreeMap<int, _BufferedAudio>();
  Timer? _drainTimer;
  bool _isOpen = false;
  bool _isPlaying = false;
  int? _sampleRate;
  int? _lastPlayedSequence;
  int jitterBufferMs = defaultJitterBufferMs;
  void Function()? onDroppedLate;

  /// Opens a raw PCM streaming speaker configured exactly like the transmitter.
  ///
  /// If sample rate/channel/codec differed from recording, byte values would
  /// play at the wrong speed or would not represent the intended waveform.
  Future<void> open({required int sampleRate}) async {
    if (_isPlaying && _sampleRate == sampleRate) {
      return;
    }
    await close();
    await _player.openPlayer();
    _isOpen = true;
    await _player.startPlayerFromStream(
      codec: Codec.pcm16,
      interleaved: true,
      numChannels: audioChannels,
      sampleRate: sampleRate,
      bufferSize: audioRecorderBufferSize,
    );
    _sampleRate = sampleRate;
    _isPlaying = true;
    _logs.info('Speaker playback ready at $sampleRate Hz');
  }

  /// Applies current-call buffering settings and a quality-stat callback.
  void configure({
    required int jitterMilliseconds,
    required void Function() whenDroppedLate,
  }) {
    jitterBufferMs = jitterMilliseconds;
    onDroppedLate = whenDroppedLate;
  }

  /// Adds an arriving packet for ordered future playout.
  ///
  /// The jitter buffer intentionally waits a small time before playback,
  /// allowing slightly late earlier packets to arrive and be sorted correctly.
  void enqueue(AudioPacket packet) {
    if (!_isPlaying || packet.payload.isEmpty) {
      return;
    }
    final lastPlayed = _lastPlayedSequence;
    if (lastPlayed != null && packet.sequenceNumber <= lastPlayed) {
      // Sound that belongs before bytes already sent to the speaker cannot be
      // inserted retroactively; playing it now would scramble spoken words.
      onDroppedLate?.call();
      return;
    }
    _buffer[packet.sequenceNumber] =
        _BufferedAudio(packet: packet, arrivedAt: DateTime.now());
    _drainTimer ??= Timer.periodic(
      const Duration(milliseconds: 10),
      _drainReady,
    );
  }

  /// Clears queued audio and releases the native speaker stream at call end.
  Future<void> stopStream() async {
    _drainTimer?.cancel();
    _drainTimer = null;
    _buffer.clear();
    _lastPlayedSequence = null;
    if (_isPlaying) {
      await _player.stopPlayer();
      _isPlaying = false;
    }
    if (_isOpen) {
      await _player.closePlayer();
      _isOpen = false;
    }
    _sampleRate = null;
  }

  Future<void> close() => stopStream();

  /// Periodically emits every packet that has waited the configured delay.
  ///
  /// Waiting forever for a missing sequence would freeze the conversation.
  /// Once ready packets have waited enough, they are played in available order.
  void _drainReady(Timer timer) {
    if (_buffer.isEmpty) {
      timer.cancel();
      _drainTimer = null;
      return;
    }
    final now = DateTime.now();
    while (_buffer.isNotEmpty) {
      final sequence = _buffer.firstKey()!;
      final candidate = _buffer[sequence]!;
      if (now.difference(candidate.arrivedAt).inMilliseconds < jitterBufferMs) {
        break;
      }
      _buffer.remove(sequence);
      final staleThreshold = jitterBufferMs * 6 + 300;
      if (now.difference(candidate.arrivedAt).inMilliseconds > staleThreshold) {
        // Very old sound increases conversational lag more than it helps
        // intelligibility, so it is discarded and reflected in diagnostics.
        onDroppedLate?.call();
        continue;
      }
      _player.uint8ListSink?.add(candidate.packet.payload);
      _lastPlayedSequence = sequence;
    }
  }
}

class _BufferedAudio {
  const _BufferedAudio({
    required this.packet,
    required this.arrivedAt,
  });

  /// Protocol packet containing its ordering sequence and PCM samples.
  final AudioPacket packet;

  /// Local clock value used to determine when its jitter wait has elapsed.
  final DateTime arrivedAt;
}
