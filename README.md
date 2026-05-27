# PeerTalk

Android-first Flutter MVP for offline local Wi-Fi push-to-talk voice.

PeerTalk is built for two Android phones on the same local network. One phone can host a hotspot and the other can join it, or both phones can join the same Wi-Fi router. The app does not use accounts, login, cloud servers, internet APIs, video, or WebRTC.

## Read the code as a lesson

The source has intentionally detailed comments. A productive reading order is:

1. Start with `lib/services/app_constants.dart` to see the protocol agreement: ports, audio settings, and audio packet bytes.
2. Read `lib/models/network_snapshot.dart` and `lib/services/network_info_service.dart` to learn what IP address, subnet mask, gateway, and broadcast address mean.
3. Read `lib/services/peer_discovery_service.dart` to follow UDP broadcast discovery.
4. Read `lib/services/audio_capture_service.dart`, then `udp_audio_sender.dart`, `udp_audio_receiver.dart`, and `audio_playback_service.dart` to follow a spoken sound from microphone to the other speaker.
5. Read `lib/services/call_controller.dart` to see how permissions, sockets, and push-to-talk state are coordinated.
6. Finish with `lib/main.dart` and `android/app/src/main/AndroidManifest.xml` to connect Flutter interactions to Android capabilities.

Generated files such as `pubspec.lock`, `GeneratedPluginRegistrant.java`, wrapper scripts, APK build output, and icon binaries are deliberately not hand-commented: Flutter and Gradle regenerate or manage them.

## Version 1 scope

- Push-to-talk half-duplex audio.
- UDP broadcast peer discovery on the LAN.
- Manual IP fallback when broadcast is filtered by a hotspot or router.
- UDP PCM16 mono audio streaming.
- Local IP, Wi-Fi, gateway, subnet, and broadcast display.
- Connection state and debug logs for discovery/audio packets.

## Flutter packages

- `permission_handler` for microphone and Android Wi-Fi info permissions.
- `network_info_plus` for current Wi-Fi/IP information.
- `udp` for UDP discovery and audio sockets.
- `flutter_sound` for PCM microphone capture and stream playback.

This workspace targets Flutter 3.24.5 / Dart 3.5.x, so `network_info_plus` is constrained to the `6.x` line and `flutter_sound` is constrained to `9.28.x` instead of newer releases that require a newer Dart/Flutter Gradle stack.

## Android permissions

The Android manifest includes:

- `RECORD_AUDIO`
- `MODIFY_AUDIO_SETTINGS`
- `INTERNET`
- `ACCESS_NETWORK_STATE`
- `ACCESS_WIFI_STATE`
- `CHANGE_WIFI_MULTICAST_STATE`
- `ACCESS_COARSE_LOCATION`
- `ACCESS_FINE_LOCATION`
- `NEARBY_WIFI_DEVICES`

Android uses the `INTERNET` permission for local sockets too. PeerTalk still has no cloud or internet dependency.

## Ports and audio format

- Discovery UDP port: `45454`
- Audio UDP port: `45455`
- Audio: PCM16, mono, 16 kHz
- Audio transport: small UDP packets with a 16-byte PeerTalk header
- Playback: small jitter buffer before feeding Flutter Sound
- Minimum Android SDK: 24
- Android build stack: AGP 8.3.2, Gradle 8.5, Kotlin 1.9.20, NDK 25.1.8937393

## How the communication works

There is no server. Both phones run the same sequence:

```text
Open app
  -> Android grants microphone/Wi-Fi metadata access
  -> app binds UDP discovery port 45454 and audio port 45455
  -> app broadcasts a small JSON "hello" on the local Wi-Fi LAN
  -> another phone replies directly and becomes selectable
  -> holding the talk button starts PCM microphone samples
  -> samples are split into small binary UDP packets sent to selected IP
  -> receiving phone validates packets, buffers briefly, and plays PCM bytes
```

If broadcast announcements are filtered by a hotspot/router, manual IP skips only discovery. It still uses the same direct UDP audio transport.

### Local IP and subnet example

Suppose Phone A hosts a hotspot and reports `192.168.43.1` with subnet mask `255.255.255.0`. Phone B may receive `192.168.43.152`. The `192.168.43` portion identifies their local subnet; the final number identifies each phone. A calculated broadcast address of `192.168.43.255` addresses devices on that subnet.

Internet access is not part of this path. The hotspot acts as a local Wi-Fi access point/router even when it has no upstream data connection.

### Why UDP instead of TCP

TCP provides reliable ordered delivery by retransmitting missing data. For files, that is excellent. For live voice, waiting to resend a stale sound can increase delay behind the speaker's current words. UDP sends datagrams immediately without delivery or order guarantees, which minimizes latency at the cost of occasional missing or late audio.

This MVP accepts that tradeoff and leaves packet-loss concealment and reordering as later improvements.

### Why raw PCM audio

PCM16 mono at 16 kHz is straightforward: the microphone emits 16-bit sound samples and the receiving speaker plays the same kind of samples. It avoids encoder/decoder complexity while validating the network design. Its approximate payload bandwidth is:

```text
16,000 samples/second x 2 bytes/sample x 1 channel = 32,000 bytes/second
```

A future Opus voice codec would use less bandwidth and handle network problems better, but adds compression and codec lifecycle concerns.

### Audio packet structure

Each binary UDP audio packet contains a 16-byte header followed by up to 960 PCM bytes:

| Bytes | Field | Purpose |
| --- | --- | --- |
| `0..3` | `PTAU` | Identifies a PeerTalk audio packet |
| `4` | Protocol version | Prevents misreading an incompatible future layout |
| `5` | Flags/reserved | Available for future optional behavior |
| `6..7` | Payload length | Number of PCM bytes after the header |
| `8..11` | Sequence number | Enables later loss/order detection |
| `12..15` | Timestamp portion | Enables later timing/jitter analysis |
| `16..` | PCM payload | Actual speaker audio sample bytes |

Smaller packets avoid network fragmentation and reduce latency. The receive side currently buffers packets for about 60 ms before playback to smooth irregular Wi-Fi delivery timing.

## Setup

```powershell
flutter pub get
flutter run
```

For a debug APK:

```powershell
flutter build apk --debug
```

## Test with two Android phones

1. Install the app on both phones.
2. Turn on hotspot on Phone A.
3. Connect Phone B to Phone A's hotspot.
4. Open PeerTalk on both phones.
5. Accept microphone and Wi-Fi/network info permissions.
6. Confirm each phone shows a local IP address.
7. Wait for UDP discovery to show the other phone in the peer list.
8. If no peer appears, enter the other phone's local IP in `Manual IP` and tap `Connect`.
9. Select the peer.
10. Press and hold `HOLD TO TALK` on one phone and speak.
11. Release the button before the other phone talks back.

The same flow works when both phones are connected to the same Wi-Fi router.

## Troubleshooting

- If discovery does not find peers, use manual IP. Some Android hotspots and routers filter broadcast packets.
- If Wi-Fi name or subnet fields are blank, re-open Android settings and ensure precise location/Wi-Fi permission is allowed for the app.
- If audio is choppy, keep phones close, test on a less congested Wi-Fi channel, and avoid both users talking at once.
- If the receiving phone shows packet logs but no sound, check media volume and Bluetooth routing.
- If one phone cannot receive packets, verify both devices are on the same subnet and that no VPN/firewall app is active.

## Project layout

```text
lib/
  main.dart
  models/
    debug_log_entry.dart
    network_snapshot.dart
    peer.dart
  services/
    audio_capture_service.dart
    audio_playback_service.dart
    call_controller.dart
    network_info_service.dart
    peer_discovery_service.dart
    udp_audio_receiver.dart
    udp_audio_sender.dart
```

## Background topics to read next

Read these in roughly this order:

1. **Local-area networks and private IPv4 addresses**: understand why `192.168.x.x`/`10.x.x.x` addresses work without internet.
2. **Subnet masks and broadcast addresses**: learn how one device announces itself before it knows a peer IP.
3. **UDP sockets, ports, datagrams, broadcast, and unicast**: these are the networking foundation of discovery and live audio in this app.
4. **TCP versus UDP for real-time media**: understand reliability versus latency tradeoffs.
5. **Digital audio fundamentals**: PCM, sample rate, bit depth, channels, buffering, and why raw audio consumes bandwidth.
6. **Jitter, packet loss, latency, and jitter buffers**: these explain why live network audio may sound uneven and how players compensate.
7. **Binary protocol design**: magic bytes, headers, payload lengths, sequence numbers, endianness, and validating untrusted packet data.
8. **Android runtime permissions and Wi-Fi privacy behavior**: microphone access and why Wi-Fi identifiers require user permission.
9. **Flutter plugins and platform channels**: how Dart code reaches Android's microphone, speaker, and network APIs without custom Kotlin in this MVP.
10. **Gradle and Android SDK levels**: why plugins dictate `minSdk`, `compileSdk`, NDK, and Java/Kotlin build settings.
11. **Audio codecs such as Opus**: the natural next step after a PCM prototype works.
12. **Full-duplex voice engineering**: acoustic echo cancellation, noise suppression, audio focus, and simultaneous send/receive challenges.

Useful starting documentation:

- Dart UDP sockets: <https://api.dart.dev/dart-io/RawDatagramSocket-class.html>
- Android permissions overview: <https://developer.android.com/guide/topics/permissions/overview>
- Android nearby Wi-Fi permissions: <https://developer.android.com/develop/connectivity/wifi/wifi-permissions>
- Flutter platform integration: <https://docs.flutter.dev/platform-integration/platform-channels>
- Flutter Sound package: <https://pub.dev/packages/flutter_sound>
- `network_info_plus` package: <https://pub.dev/packages/network_info_plus>
- `permission_handler` package: <https://pub.dev/packages/permission_handler>
- `udp` package: <https://pub.dev/packages/udp>

## Next version ideas

- Adaptive packet loss concealment.
- Opus codec support for lower bandwidth.
- Better Android audio focus and route controls.
- Persistent device names.
- Full-duplex calling only after UDP PCM stability is proven.
