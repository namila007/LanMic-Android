import 'dart:convert';
import 'dart:typed_data';

const kPort = 5004;
const kMagic = 0x4D54;
const kVersion = 1;
const kHeaderBytes = 12;
const kFrameBytes = 960;
const kSamplesPerFrame = 480;
const kSampleRate = 48000;
const kMaxDatagram = 972;
const kAckNameMaxBytes = 32;

/// Wire value = enum index.
enum PacketType { audio, hello, ack, end, reject, stats }

/// Wire value = enum index; a byte > 3 decodes as unknown.
enum WifiBand { unknown, ghz2_4, ghz5, ghz6 }

const kUnknownU16 = 0xFFFF;
const kHelloInfoBytes = 4;
const kStatsBytes = 7;

typedef HelloInfo = ({int? rttMs, int? delayMs});

class StatsReport {
  const StatsReport({this.tvDelayMs, this.lostPermille, this.jitterMs, this.band = WifiBand.unknown});
  final int? tvDelayMs;
  final int? lostPermille;
  final int? jitterMs;
  final WifiBand band;

  @override
  bool operator ==(Object other) =>
      other is StatsReport &&
      other.tvDelayMs == tvDelayMs &&
      other.lostPermille == lostPermille &&
      other.jitterMs == jitterMs &&
      other.band == band;

  @override
  int get hashCode => Object.hash(tvDelayMs, lostPermille, jitterMs, band);
}

class Packet {
  Packet._(this.type, this.seq, this.pin, this.payload) {
    _checkU32(seq, 'seq');
    _checkU32(pin, 'pin');
  }

  Packet.hello(int seq, int pin, [HelloInfo? info])
      : this._(PacketType.hello, seq, pin, info == null ? Uint8List(0) : _u16s([info.rttMs, info.delayMs]));
  Packet.end(int seq, int pin) : this._(PacketType.end, seq, pin, Uint8List(0));
  Packet.reject(int seq, int pin) : this._(PacketType.reject, seq, pin, Uint8List(0));
  Packet.stats(int seq, int pin, StatsReport r)
      : this._(PacketType.stats, seq, pin,
            _u16s([r.tvDelayMs, r.lostPermille, r.jitterMs], extra: r.band.index));
  Packet.ack(int seq, int pin, String tvName)
      : this._(PacketType.ack, seq, pin, _truncate(tvName));
  Packet.audio(int seq, int pin, Uint8List frame)
      : this._(PacketType.audio, seq, pin, _frame(frame));

  final PacketType type;
  final int seq;
  final int pin;
  final Uint8List payload;

  String? get ackName =>
      type == PacketType.ack ? utf8.decode(payload, allowMalformed: true) : null;

  HelloInfo? get helloInfo {
    if (type != PacketType.hello || payload.length < kHelloInfoBytes) return null;
    final bd = ByteData.sublistView(payload);
    return (rttMs: _readU16(bd, 0), delayMs: _readU16(bd, 2));
  }

  StatsReport? get statsReport {
    if (type != PacketType.stats || payload.length < kStatsBytes) return null;
    final bd = ByteData.sublistView(payload);
    final b = bd.getUint8(6);
    return StatsReport(
      tvDelayMs: _readU16(bd, 0),
      lostPermille: _readU16(bd, 2),
      jitterMs: _readU16(bd, 4),
      band: b < WifiBand.values.length ? WifiBand.values[b] : WifiBand.unknown,
    );
  }
}

int? _readU16(ByteData bd, int o) {
  final v = bd.getUint16(o, Endian.little);
  return v == kUnknownU16 ? null : v;
}

/// Null -> 0xFFFF; otherwise clamped to 0..0xFFFE so a big value never reads as unknown.
Uint8List _u16s(List<int?> vals, {int? extra}) {
  final out = Uint8List(vals.length * 2 + (extra == null ? 0 : 1));
  final bd = ByteData.sublistView(out);
  for (var i = 0; i < vals.length; i++) {
    final v = vals[i];
    bd.setUint16(i * 2, v == null ? kUnknownU16 : v.clamp(0, 0xFFFE), Endian.little);
  }
  if (extra != null) bd.setUint8(vals.length * 2, extra);
  return out;
}

void _checkU32(int v, String name) {
  if (v < 0 || v > 0xFFFFFFFF) throw ArgumentError.value(v, name, 'must be u32');
}

Uint8List _frame(Uint8List f) {
  if (f.length != kFrameBytes) throw ArgumentError.value(f.length, 'frame', 'must be $kFrameBytes bytes');
  return f;
}

Uint8List _truncate(String name) {
  // Drop whole runes until it fits so a code point is never split.
  final runes = name.runes.toList();
  var bytes = utf8.encode(name);
  while (bytes.length > kAckNameMaxBytes) {
    runes.removeLast();
    bytes = utf8.encode(String.fromCharCodes(runes));
  }
  return Uint8List.fromList(bytes);
}

Uint8List encodePacket(Packet p) {
  final out = Uint8List(kHeaderBytes + p.payload.length);
  final bd = ByteData.sublistView(out);
  bd.setUint16(0, kMagic, Endian.little);
  bd.setUint8(2, kVersion);
  bd.setUint8(3, p.type.index);
  bd.setUint32(4, p.seq, Endian.little);
  bd.setUint32(8, p.pin, Endian.little);
  out.setRange(kHeaderBytes, out.length, p.payload);
  return out;
}

/// Returns null for anything malformed. Does not check the PIN.
Packet? decodePacket(Uint8List bytes) {
  if (bytes.length < kHeaderBytes || bytes.length > kMaxDatagram) return null;
  final bd = ByteData.sublistView(bytes);
  if (bd.getUint16(0, Endian.little) != kMagic || bd.getUint8(2) != kVersion) return null;
  final t = bd.getUint8(3);
  if (t >= PacketType.values.length) return null;
  final type = PacketType.values[t];
  final payload = Uint8List.fromList(bytes.sublist(kHeaderBytes));
  if (type == PacketType.audio && payload.length != kFrameBytes) return null;
  if (type == PacketType.stats && payload.length < kStatsBytes) return null;
  return Packet._(type, bd.getUint32(4, Endian.little), bd.getUint32(8, Endian.little), payload);
}
