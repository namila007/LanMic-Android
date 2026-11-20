import 'package:flutter_test/flutter_test.dart';
import 'package:lanmic_protocol/lanmic_protocol.dart';
import 'package:lanmic_tv/domain/session_registry.dart';

import 'dart:typed_data';

void main() {
  const pin = 482917;
  const a = Peer('192.168.1.10', 4000);
  const b = Peer('192.168.1.11', 4000);
  var t = DateTime(2026);
  late SessionRegistry r;
  void at(int ms) => t = DateTime(2026).add(Duration(milliseconds: ms));
  setUp(() {
    at(0);
    r = SessionRegistry(pin: pin, name: 'Chromecast', now: () => t);
  });

  final audio = Packet.audio(1, pin, Uint8List(kFrameBytes));

  test('valid HELLO -> ACK', () {
    final res = r.onPacket(Packet.hello(1, pin), a);
    expect(res.reply!.type, PacketType.ack);
    expect(res.reply!.ackName, 'Chromecast');
    expect(r.activePhone, a);
  });

  test('wrong-PIN HELLO -> REJECT, rate limited to 1/s per source', () {
    expect(r.onPacket(Packet.hello(1, 1), a).reply!.type, PacketType.reject);
    expect(r.activePhone, isNull);
    at(900);
    expect(r.onPacket(Packet.hello(1, 1), a).reply, isNull);
    at(1000);
    expect(r.onPacket(Packet.hello(1, 1), a).reply!.type, PacketType.reject);
  });

  test('wrong-PIN HELLO leaves the active phone alone', () {
    r.onPacket(Packet.hello(1, pin), a);
    r.onPacket(Packet.hello(1, 1), b);
    expect(r.activePhone, a);
  });

  test('AUDIO before HELLO, wrong PIN, or other port is dropped', () {
    var res = r.onPacket(audio, a);
    expect((res.audio, res.reply), (false, null));
    r.onPacket(Packet.hello(1, pin), a);
    expect(
      r.onPacket(Packet.audio(1, 1, Uint8List(kFrameBytes)), a).audio,
      isFalse,
    );
    res = r.onPacket(audio, const Peer('192.168.1.10', 4001));
    expect((res.audio, res.reply), (false, null));
    expect(r.onPacket(audio, a).audio, isTrue);
  });

  test('second phone replaces first', () {
    r.onPacket(Packet.hello(1, pin), a);
    r.onPacket(Packet.hello(1, pin), b);
    expect(r.onPacket(audio, a).audio, isFalse);
    expect(r.onPacket(audio, b).audio, isTrue);
  });

  test('gone after 6 s without HELLO; HELLO resets the window', () {
    r.onPacket(Packet.hello(1, pin), a);
    at(2000);
    r.onPacket(Packet.hello(2, pin), a);
    at(7999);
    expect(r.activePhone, a);
    at(8000);
    expect(r.activePhone, isNull);
    expect(r.onPacket(audio, a).audio, isFalse);
  });

  test('END from active -> end; from other peer or wrong PIN -> not', () {
    r.onPacket(Packet.hello(1, pin), a);
    expect(r.onPacket(Packet.end(9, pin), b).end, isFalse);
    expect(r.onPacket(Packet.end(9, 1), a).end, isFalse);
    expect(r.onPacket(Packet.end(9, pin), a).end, isTrue);
  });

  test('inbound ack/reject are dropped', () {
    r.onPacket(Packet.hello(1, pin), a);
    for (final p in [Packet.ack(1, pin, 'x'), Packet.reject(1, pin)]) {
      final res = r.onPacket(p, a);
      expect((res.reply, res.audio, res.end), (null, false, false));
    }
  });

  test('long name is truncated to valid UTF-8 within 32 B', () {
    r = SessionRegistry(pin: pin, name: 'é' * 40, now: () => t);
    final p = r.onPacket(Packet.hello(1, pin), a).reply!;
    expect(p.payload.length, lessThanOrEqualTo(kAckNameMaxBytes));
    expect(p.ackName, 'é' * 16);
  });
}
