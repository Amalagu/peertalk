/// Shared "wire protocol" values used by both phones.
///
/// A network protocol is simply an agreement about ports and byte layout.
/// Because there is no server to translate messages, the sending phone and the
/// receiving phone must use exactly the same values in this file.
const appProtocolName = 'PeerTalk';

/// Allows future versions to reject packets whose format has changed.
const appProtocolVersion = 1;

/// UDP uses numbered ports like apartment numbers at an IP address. Discovery
/// packets arrive at one well-known port, while continuous audio uses another,
/// keeping the two kinds of traffic simple to identify and debug.
const discoveryPort = 45454;
const audioPort = 45455;

/// Raw audio settings. PCM16 means each sample is a signed 16-bit measurement
/// of sound pressure; mono sends one channel. At 16,000 samples/second this is
/// 32,000 bytes/second before our small packet header, acceptable on Wi-Fi and
/// much easier to implement than compressed codecs such as Opus.
const audioSampleRate = 16000;
const audioChannels = 1;

/// Flutter Sound supplies microphone bytes in chunks. This is an internal
/// plugin buffer size and is not the maximum UDP datagram size below.
const audioRecorderBufferSize = 2048;

/// Payload bytes per UDP audio packet. Small packets produce lower latency and
/// avoid IP fragmentation: a typical Wi-Fi/Ethernet MTU is 1500 bytes, and
/// this stays safely below it after UDP/IP and PeerTalk headers are added.
const maxAudioPayloadBytes = 960;

/// Four identifying bytes at the front of every audio packet: ASCII "PTAU",
/// short for "PeerTalk AUdio". They prevent an unrelated UDP message received
/// on the port from being interpreted as speaker audio.
const audioMagicP = 0x50;
const audioMagicT = 0x54;
const audioMagicA = 0x41;
const audioMagicU = 0x55;

/// Packet header layout, followed immediately by PCM bytes:
/// bytes 0..3  = `PTAU` magic marker
/// byte 4      = protocol version
/// byte 5      = reserved flags byte for future use
/// bytes 6..7  = audio payload length
/// bytes 8..11 = monotonically increasing packet sequence number
/// bytes 12..15 = truncated sender timestamp in milliseconds
const audioHeaderBytes = 16;

/// Discovery messages are JSON, unlike the binary audio packets because they
/// are tiny and human-readable in diagnostics. `hello` asks who is present;
/// `here` is a direct answer to the asking phone.
const discoveryHello = 'hello';
const discoveryHere = 'here';
