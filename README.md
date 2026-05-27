# PeerTalk V2

Android-first Flutter voice calling over a local Wi-Fi network or phone hotspot.
PeerTalk has no accounts, cloud server, internet API, video, or WebRTC. Two
phones communicate directly through UDP on the same LAN.

## Version 2 capabilities

- Periodic UDP peer announcements with device name, IP address, modes, and stale-peer removal.
- Manual IP fallback when a router or hotspot blocks broadcast discovery.
- Offline outgoing/incoming call flow with accept, reject, cancel, and end controls.
- Unique session IDs so stale packets from ended calls are ignored.
- Repeated call invitations with answer timeout.
- Heartbeats during calls with reconnecting and peer-lost failure states.
- Push-to-talk calls, preserving Version 1 behavior as the default mode.
- Optional full-duplex calls where both microphones stream continuously.
- Session-aware PCM audio packets with sequence numbers and timestamps.
- Configurable jitter buffering and basic received packet-loss statistics.
- Speakerphone control and Android communication audio mode during calls.
- Persistent settings and a dedicated debug log screen.

Calls are intentionally **foreground-only** in Version 2. Keep PeerTalk visible
on both phones during a call. A later version could add an Android foreground
service and notification for background calling.

## Read the source in order

The code contains learning-oriented comments. A useful tour is:

1. `lib/services/app_constants.dart`: UDP ports, timing defaults, and the binary audio header.
2. `lib/models/communication_mode.dart`, `peer.dart`, and `call_session.dart`: the product's vocabulary.
3. `lib/models/control_packet.dart` and `audio_packet.dart`: JSON signaling versus binary media.
4. `lib/services/network_info_service.dart`, `peer_registry.dart`, and `peer_discovery_service.dart`: local addresses, announcements, and expiry.
5. `lib/services/call_signaling_service.dart` and `call_controller.dart`: ringing, collision handling, timeouts, heartbeat, and reconnect behavior.
6. `lib/services/audio_capture_service.dart`, `udp_audio_transport.dart`, and `audio_playback_service.dart`: microphone-to-speaker media path.
7. `lib/services/audio_route_service.dart` and `android/app/src/main/kotlin/.../MainActivity.kt`: the small Android speaker/call-mode bridge.
8. `lib/main.dart`: peer, settings, log, ringing, and active-call Flutter surfaces.

Generated files such as `pubspec.lock`, Flutter plugin registration, Gradle
wrapper scripts, launcher binaries, and APK output are not hand-annotated.

## Architecture

```text
Home / Settings / Logs / Call screens
                  |
            CallController
       ___________|____________________________
      |           |             |              |
PeerRegistry  CallSignaling  AudioTransport  AppSettings
      |           |             |              |
 Discovery UDP  Control UDP   Audio UDP     SharedPreferences
                              /       \
                       Mic capture   Jittered playback
                                         |
                             Android audio-route channel
```

Important services:

| Service | Responsibility |
| --- | --- |
| `PeerDiscoveryService` | Broadcast/receive LAN presence messages on UDP `45454` |
| `PeerRegistry` | Store peers, last-seen time, and remove stale discovered peers |
| `CallSignalingService` | Send/receive invite, answer, end, and heartbeat messages on UDP `45456` |
| `CallController` | Own call state transitions and coordinate media/UI |
| `UdpAudioTransport` | Send/receive session-tagged binary audio on UDP `45455` |
| `AudioCaptureService` | Stream PCM16 microphone samples using Flutter Sound |
| `AudioPlaybackService` | Reorder briefly, drop late packets, and play audio |
| `AudioRouteService` | Request Android communication mode and speakerphone routing |
| `AppSettingsService` | Persist device name, audio mode, tuning, and logs preference |
| `DebugLogService` | Keep bounded diagnostic events for device testing |

### Flutter layout lesson from the call and log screens

Flutter lays out a widget by passing it constraints from its parent, rather
than by letting each child assume it owns the physical screen. The Logs tab is
already inside a `Scaffold`, app bar, safe area, navigation bar, card padding,
and title row. Its black terminal area therefore uses `Expanded` to consume the
remaining height given by that real parent chain. Calculating its height from
the entire phone screen would allocate space that the surrounding UI already
uses and create the familiar yellow/black overflow warning.

The ringing and ended call surfaces use a full available layout region plus a
centered, maximum-width content column. This keeps the call identity and
controls in the visual center on phones, landscape rotation, and wider Android
screens instead of stretching the content toward one side.

## LAN discovery

Each app periodically broadcasts a small JSON announcement:

```json
{
  "app": "PeerTalk",
  "version": 2,
  "type": "hello",
  "deviceId": "temporary-session-device-id",
  "name": "Kitchen phone",
  "ip": "192.168.43.152",
  "audioPort": 45455,
  "controlPort": 45456,
  "discoveryPort": 45454,
  "supportedModes": ["push_to_talk", "full_duplex"]
}
```

A peer remains visible while announcements refresh its `lastSeen` value.
Automatically discovered peers disappear after approximately three discovery
intervals without an update. A manually entered peer remains listed because
there was no announcement stream to judge.

Example hotspot LAN:

```text
Phone A hotspot: 192.168.43.1
Phone B client:  192.168.43.152
Subnet mask:     255.255.255.0
Broadcast:       192.168.43.255
```

The phones communicate inside that local subnet even if the hotspot has no
internet connection.

## Call signaling

Call control messages are JSON UDP datagrams. Every message includes a unique
`sessionId`, sender details, timestamp, and call metadata.

| Packet | Purpose |
| --- | --- |
| `CALL_INVITE` | Start ringing the remote phone and propose mode/sample rate |
| `CALL_ACCEPT` | Confirm that media for this session may begin |
| `CALL_REJECT` | Decline an invite or report busy |
| `CALL_END` | End the current matched session |
| `HEARTBEAT` | Prove an accepted call still reaches the peer |
| `HEARTBEAT_ACK` | Confirm the heartbeat arrived |

UDP does not guarantee delivery. Outgoing invites are repeated until accepted,
rejected, cancelled, or timed out. Connected calls send heartbeat traffic every
two seconds; a temporary gap displays `Connecting`, and a longer gap fails the
call with a clear message.

If both devices call at almost the same instant, both use a deterministic
device-ID comparison: one outbound session wins and the other device changes
to the incoming-call flow instead of leaving both phones permanently busy.

## Audio pipeline

PeerTalk uses PCM16 mono audio rather than compression in this prototype:

```text
16,000 samples/sec x 2 bytes/sample x 1 channel = 32,000 bytes/sec
```

The Settings screen also permits `8 kHz` and `24 kHz`; the caller proposes the
selected rate inside the invitation, and both ends play/capture that rate for
the accepted session.

Each V2 UDP audio datagram includes session identity:

| Bytes | Field | Purpose |
| --- | --- | --- |
| `0..3` | `PTA2` | Identifies a PeerTalk V2 audio datagram |
| `4` | Version | Reject incompatible formats |
| `5` | Packet type | `1` represents audio |
| `6..7` | Metadata length | Size of following UTF-8 JSON identity block |
| `8..9` | Payload length | Size of PCM samples in this datagram |
| `10..13` | Sequence number | Detect gaps and late/out-of-order packets |
| `14..21` | Timestamp | Sender capture/send time in milliseconds |
| `22..` | Metadata + PCM | `sessionId`, `senderId`, then sound bytes |

Audio is sent only to the selected/answered peer IP, never broadcast. Received
audio must match the active session and remote sender. A sequence-keyed jitter
buffer waits a configurable short period before speaker playback; already
obsolete packets are dropped and shown in quality statistics.

### Push-to-talk and full-duplex

- **Push-to-talk** opens microphone capture only while the button is held and
  ignores incoming audio while transmitting. This is the robust fallback.
- **Full-duplex** begins continuous microphone streaming after acceptance and
  plays incoming audio concurrently.

For full-duplex calls, the app asks Android for `MODE_IN_COMMUNICATION`, uses
Flutter Sound's `voice_communication` recording source, and routes to
speakerphone by default. Echo cancellation remains device-dependent; headphones
or lower speaker volume may still be needed on some phones.

## Packages and Android configuration

- `permission_handler`: runtime microphone and Wi-Fi metadata permission prompts.
- `network_info_plus`: local Wi-Fi IP, subnet, gateway, and broadcast values.
- `udp`: Dart UDP sockets for discovery, signaling, and media.
- `flutter_sound`: live PCM16 recording and stream playback.
- `shared_preferences`: persistent user settings.

Android permissions in `AndroidManifest.xml` include `RECORD_AUDIO`,
`MODIFY_AUDIO_SETTINGS`, `INTERNET`, network/Wi-Fi state, multicast-state, and
location/nearby-Wi-Fi permissions. Android calls local-IP socket permission
`INTERNET`; PeerTalk still sends no cloud traffic.

- Minimum Android SDK: 24
- Compile/target SDK: 35
- Android build stack: AGP 8.3.2, Gradle 8.5, Kotlin 1.9.20, NDK 25.1.8937393

## Build and install

```powershell
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```

The generated APK is:

```text
build/app/outputs/flutter-apk/app-debug.apk
```

`test/protocol_models_test.dart` validates V2 audio/control packet round trips,
malformed audio rejection, and packet-loss gap counting.

## Test on two phones

### Phone hotspot scenario

1. Install the same APK on both Android phones.
2. Enable hotspot on Phone A.
3. Connect Phone B to Phone A's hotspot.
4. Open PeerTalk on both phones and grant requested permissions.
5. Confirm both phones show local IP addresses in the Network panel.
6. Confirm each phone appears under Available peers with `Online` status.
7. Tap a peer row to view its advertised IP, ports, and modes.
8. Tap the call icon on Phone A.
9. Confirm Phone B shows an incoming call screen.
10. Accept on Phone B and confirm both phones show `Connected`.
11. End the call and confirm both return to an ended/idle state.

### Same-router Wi-Fi scenario

1. Connect both phones to one Wi-Fi router.
2. Open PeerTalk and repeat peer discovery and call tests above.
3. Verify calls remain local by disabling internet upstream if convenient; the
   Wi-Fi LAN connection itself must remain enabled.

### Manual IP fallback

1. Note Phone B's IP in its Network panel.
2. On Phone A, enter that IP under Manual peer and add it.
3. Tap Call on the manual peer.
4. Confirm Phone B receives and can accept the call even if discovery was not visible.

### Required behavior checks

| Test | Expected result |
| --- | --- |
| Reject call | Caller shows a failed/declined result; no audio session starts |
| Cancel outgoing call | Receiver stops ringing or times out without media |
| End connected call | Other phone exits the matched session cleanly |
| Push-to-talk mode | Audio sends only while holding the talk control |
| Full-duplex mode | Both devices can speak and receive after acceptance |
| Mute | Full-duplex microphone stops sending until unmuted |
| Speaker toggle | Android call audio switches speaker routing |
| Packet loss indicator | Received sequence gaps update the displayed percentage |
| Disconnect Wi-Fi during call | Status changes toward reconnecting, then fails if peer remains absent |
| Rejoin quickly | Heartbeats can return a connecting call to connected before failure timeout |
| Stale peer removal | Close one idle app; its automatically discovered row disappears after timeout |
| Logs disabled | New routine events stop being collected; errors may still be shown |

## Current limitations

- Calls remain active only while the application is in the foreground.
- Raw PCM requires more bandwidth than a voice codec such as Opus.
- Packet-loss reporting is basic and does not conceal missing speech.
- Audio jitter buffering orders recently received packets but does not implement
  sophisticated adaptive delay.
- Echo reduction depends on the Android device's communication audio support.

## Topics to study next

1. Private IPv4 networks, hotspots, subnet masks, broadcast and unicast.
2. UDP sockets, datagrams, port binding, packet loss, and NAT-free LAN traffic.
3. Distributed session state, retries, timeouts, heartbeats, and idempotency.
4. Simultaneous-call collision resolution and deterministic conflict handling.
5. PCM audio, sampling rates, byte depth, audio routes, and Android audio focus.
6. Real-time media latency, jitter buffers, sequence numbers, and loss concealment.
7. Binary network protocols, metadata framing, validation, and endianness.
8. Android permissions, Wi-Fi privacy policies, foreground services, and notifications.
9. Flutter plugins/platform channels and native Kotlin interoperation.
10. Opus codec integration, echo cancellation, noise suppression, and production VoIP.

Starting references:

- Dart UDP sockets: <https://api.dart.dev/dart-io/RawDatagramSocket-class.html>
- Android permissions: <https://developer.android.com/guide/topics/permissions/overview>
- Android Wi-Fi permissions: <https://developer.android.com/develop/connectivity/wifi/wifi-permissions>
- Android audio input: <https://developer.android.com/reference/android/media/MediaRecorder.AudioSource>
- Flutter platform channels: <https://docs.flutter.dev/platform-integration/platform-channels>
- Flutter Sound: <https://pub.dev/packages/flutter_sound>
- `network_info_plus`: <https://pub.dev/packages/network_info_plus>
- `permission_handler`: <https://pub.dev/packages/permission_handler>
- `shared_preferences`: <https://pub.dev/packages/shared_preferences>
- `udp`: <https://pub.dev/packages/udp>
