/// Shared Version 2 "wire protocol" values used by both phones.
///
/// A network protocol is simply an agreement about ports and byte layout.
/// Because there is no server to translate messages, the sending phone and the
/// receiving phone must use exactly the same values in this file.
const appProtocolName = 'PeerTalk';

/// Allows future versions to reject packets whose format has changed.
const appProtocolVersion = 2;

/// UDP uses numbered ports like apartment numbers at an IP address. Discovery
/// packets, call signaling messages, and audio arrive at separate known ports,
/// keeping each type of traffic simple to identify and debug.
const discoveryPort = 45454;
const audioPort = 45455;
const controlPort = 45456;

/// Raw audio settings. PCM16 means each sample is a signed 16-bit measurement
/// of sound pressure; mono sends one channel. At 16,000 samples/second this is
/// 32,000 bytes/second before our small packet header, acceptable on Wi-Fi and
/// much easier to implement than compressed codecs such as Opus.
const audioSampleRate = 16000;
const audioChannels = 1;
const supportedSampleRates = <int>[8000, 16000, 24000];

/// Flutter Sound supplies microphone bytes in chunks. This is an internal
/// plugin buffer size and is not the maximum UDP datagram size below.
const audioRecorderBufferSize = 2048;

/// Payload bytes per UDP audio packet. Small packets produce lower latency and
/// avoid IP fragmentation: a typical Wi-Fi/Ethernet MTU is 1500 bytes, and
/// this stays safely below it after UDP/IP and PeerTalk headers are added.
const maxAudioPayloadBytes = 760;

/// Four identifying bytes at the front of every V2 audio packet: ASCII "PTA2",
/// short for "PeerTalk Audio version 2". They prevent unrelated traffic or V1
/// packet layouts from being played as audio in a V2 call.
const audioMagicP = 0x50;
const audioMagicT = 0x54;
const audioMagicA = 0x41;
const audioMagicVersion2 = 0x32;

/// Packet header layout, followed immediately by PCM bytes:
/// bytes 0..3  = `PTA2` magic marker
/// byte 4      = protocol version
/// byte 5      = packet type (`1` means audio)
/// bytes 6..7  = UTF-8 JSON metadata length
/// bytes 8..9  = audio payload length
/// bytes 10..13 = monotonically increasing packet sequence number
/// bytes 14..21 = timestamp in milliseconds since epoch
/// bytes 22..  = JSON metadata then PCM payload
const audioHeaderBytes = 22;
const audioPacketType = 1;

/// Discovery messages are JSON, unlike the binary audio packets because they
/// are tiny and human-readable in diagnostics. `hello` asks who is present;
/// `here` is a direct answer to the asking phone.
const discoveryHello = 'hello';
const discoveryHere = 'here';

/// Timing defaults express the reliability/latency tradeoffs of a local UDP
/// application. Discovery repeats because broadcasts can be lost; stale
/// removal waits for several missed broadcasts; call invitations give a human
/// enough time to answer; heartbeats notice a broken network during a call.
const defaultDiscoveryIntervalSeconds = 2;
const stalePeerAfterSeconds = 8;
const callInviteTimeoutSeconds = 20;
const heartbeatIntervalSeconds = 2;
const heartbeatReconnectAfterSeconds = 6;
const heartbeatFailureAfterSeconds = 12;

/// Holding received audio briefly smooths uneven arrival timing. Larger values
/// can reduce audible breakup but make speech feel less immediate.
const defaultJitterBufferMs = 60;
