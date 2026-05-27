import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_sound/flutter_sound.dart';

import 'app_constants.dart';

/// Wraps Flutter Sound microphone recording as a stream of uncompressed bytes.
///
/// A Flutter plugin bridges Dart to Android audio APIs. This class isolates
/// plugin details from networking: it does not know IP addresses or UDP; it
/// only reports PCM chunks whenever Android records another slice of speech.
class AudioCaptureService {
  /// The plugin object owns Android's microphone recorder resource.
  final FlutterSoundRecorder _recorder = FlutterSoundRecorder();

  /// Flutter Sound pushes captured bytes into this sink. We subscribe to the
  /// corresponding stream so the controller can immediately send each chunk.
  StreamController<Uint8List>? _streamController;
  StreamSubscription<Uint8List>? _streamSubscription;
  bool _isOpen = false;
  bool _isRecording = false;

  bool get isRecording => _isRecording;

  /// Acquires native recorder resources separately from actually recording.
  /// Opening once reduces the amount of setup required after a button press.
  Future<void> open() async {
    if (_isOpen) {
      return;
    }
    await _recorder.openRecorder();
    _isOpen = true;
  }

  /// Starts producing PCM16 microphone chunks until [stop] is called.
  ///
  /// PCM is an uncomplicated stream of sample values: no compression headers,
  /// decoding, or codec negotiation is needed on the other phone. The cost is
  /// higher bandwidth than a voice codec, an acceptable MVP tradeoff on Wi-Fi.
  Future<void> start({
    required void Function(Uint8List pcm) onData,
    void Function(String message)? onLog,
  }) async {
    if (_isRecording) {
      return;
    }
    await open();

    // This controller is a Dart pipe between native microphone output and the
    // caller's `onData`, which eventually reaches UdpAudioSender.
    _streamController = StreamController<Uint8List>();
    _streamSubscription = _streamController!.stream.listen(
      onData,
      onError: (Object error) => onLog?.call('Recorder stream error: $error'),
    );

    await _recorder.startRecorder(
      // Both devices must agree on these exact PCM parameters or received byte
      // values would be interpreted at the wrong speed/channel arrangement.
      codec: Codec.pcm16,
      numChannels: audioChannels,
      sampleRate: audioSampleRate,
      bufferSize: audioRecorderBufferSize,
      toStream: _streamController!.sink,
    );
    _isRecording = true;
    onLog?.call('Microphone capture started');
  }

  /// Ends capture and closes the per-transmission stream plumbing.
  ///
  /// Stopping on release implements half-duplex push-to-talk and, importantly,
  /// avoids the receiving phone's speaker audio feeding back into its mic.
  Future<void> stop({void Function(String message)? onLog}) async {
    if (!_isRecording) {
      return;
    }
    await _recorder.stopRecorder();
    _isRecording = false;
    await _streamSubscription?.cancel();
    _streamSubscription = null;
    await _streamController?.close();
    _streamController = null;
    onLog?.call('Microphone capture stopped');
  }

  /// Releases the native recorder when leaving the screen/application.
  Future<void> close() async {
    await stop();
    if (_isOpen) {
      await _recorder.closeRecorder();
      _isOpen = false;
    }
  }
}
