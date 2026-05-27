package com.peertalk.peer_talk

import android.content.Context
import android.media.AudioManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// Android starts this Activity when the launcher icon is tapped. FlutterActivity
// boots the Dart engine and displays the widget tree from lib/main.dart.
// Version 2 adds one narrow platform channel because Flutter Sound streams PCM
// audio but does not expose Android speakerphone/communication routing here.
class MainActivity : FlutterActivity() {
    // A MethodChannel is a named request/reply bridge between Dart and Android.
    // This exact string is repeated in AudioRouteService on the Flutter side.
    private val channelName = "com.peertalk.peer_talk/audio_route"

    // AudioManager is the native Android service that selects voice-call
    // routing behavior such as communication mode and loud-speaker output.
    private lateinit var audioManager: AudioManager

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager

        // Flutter sends small method calls here; PCM audio itself never crosses
        // this channel because flutter_sound already streams it efficiently.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "beginCall" -> {
                        // Arguments are Dart map values decoded by Flutter's
                        // standard codec. Default speakerphone is useful for an
                        // intercom when an older caller omits the argument.
                        val speakerphone = call.argument<Boolean>("speakerphone") ?: true
                        beginCommunicationAudio(speakerphone)
                        result.success(null)
                    }
                    "setSpeakerphone" -> {
                        // This can be toggled while the active audio stream
                        // continues; no network renegotiation is required.
                        val enabled = call.argument<Boolean>("enabled") ?: true
                        setSpeakerphone(enabled)
                        result.success(null)
                    }
                    "endCall" -> {
                        // Always return ordinary device audio behavior after a
                        // call so music/notifications are not left call-routed.
                        endCommunicationAudio()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // Android has newer per-device routing APIs on recent OS releases, but the
    // speakerphone property remains a compact Android-first MVP solution that
    // works across the phone versions supported by this Flutter project.
    @Suppress("DEPRECATION")
    private fun beginCommunicationAudio(speakerphone: Boolean) {
        // MODE_IN_COMMUNICATION tells Android that this audio is a voice chat;
        // supported devices may enable voice processing such as echo control.
        audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
        audioManager.isSpeakerphoneOn = speakerphone
    }

    @Suppress("DEPRECATION")
    private fun setSpeakerphone(enabled: Boolean) {
        audioManager.isSpeakerphoneOn = enabled
    }

    @Suppress("DEPRECATION")
    private fun endCommunicationAudio() {
        // Resetting both output choice and mode avoids leaking call-oriented
        // audio configuration into normal application/system playback.
        audioManager.isSpeakerphoneOn = false
        audioManager.mode = AudioManager.MODE_NORMAL
    }
}
