@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanmic/data/services/session_service.dart';
import 'package:lanmic/data/services/udp_sender.dart';
import 'package:lanmic/domain/phone_state.dart';
import 'package:lanmic_protocol/lanmic_protocol.dart';

import '../support/fake_tv.dart';

const pin = 482917;
final lo = InternetAddress.loopbackIPv4;

Future<void> until(
  SessionService s,
  PhoneState want, {
  Duration max = const Duration(seconds: 10),
}) async {
  if (s.state == want) return;
  await s.states.firstWhere((x) => x == want).timeout(max);
}

Future<void> wait(Duration d) => Future<void>.delayed(d);

void main() {
  late FakeTv tv;
  late UdpSender sender;
  late SessionService s;

  setUp(() async {
    tv = await FakeTv.start(pin: pin);
    sender = await UdpSender.bind();
    s = SessionService(sender: sender, port: tv.port);
  });
  tearDown(() async {
    await s.disconnect();
    await sender.close();
    tv.close();
  });

  test('happy path: connected, tvName, first datagram is HELLO', () async {
    await s.connect(lo, pin);
    await until(s, PhoneState.connected);
    expect(s.tvName, 'Living Room');
    expect(tv.received.first.type, PacketType.hello);
    expect(tv.received.first.pin, pin);
  });

  test('wrong PIN -> wrongPin', () async {
    await s.connect(lo, 111111);
    await until(s, PhoneState.wrongPin);
  });

  test('no response -> noResponse in 3.0-3.4 s after 3 HELLOs', () async {
    tv.answer = false;
    final sw = Stopwatch()..start();
    await s.connect(lo, pin);
    await until(s, PhoneState.noResponse);
    expect(sw.elapsedMilliseconds, inInclusiveRange(3000, 3400));
    await wait(const Duration(milliseconds: 300));
    expect(tv.count(PacketType.hello), 3);
  });

  test(
    'TV stops answering -> lost at ~6 s, HELLO continues, recovers',
    () async {
      await s.connect(lo, pin);
      await until(s, PhoneState.connected);
      tv.answer = false;
      final sw = Stopwatch()..start();
      await until(s, PhoneState.lost);
      expect(sw.elapsedMilliseconds, inInclusiveRange(5700, 6600));
      final before = tv.count(PacketType.hello);
      await wait(const Duration(milliseconds: 4200));
      expect(tv.count(PacketType.hello) - before, greaterThanOrEqualTo(2));
      tv.answer = true;
      await until(s, PhoneState.connected);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test('ACK from another port is ignored', () async {
    tv.answer = false;
    await s.connect(lo, pin);
    final other = await RawDatagramSocket.bind(lo, 0);
    other.send(encodePacket(Packet.ack(0, pin, 'Evil')), lo, sender.port);
    await wait(const Duration(milliseconds: 300));
    expect(s.state, PhoneState.connecting);
    other.close();
  });

  test('ACK after disconnect is ignored; no HELLO after disconnect', () async {
    await s.connect(lo, pin);
    await until(s, PhoneState.connected);
    await s.disconnect();
    final n = tv.count(PacketType.hello);
    tv.sendTo(Packet.ack(0, pin, 'x'), lo, sender.port);
    await wait(const Duration(milliseconds: 2500));
    expect(s.state, PhoneState.disconnected);
    expect(tv.count(PacketType.hello), n);
  });

  test('send failure (closed sender) -> noResponse, no exception', () async {
    await sender.close();
    await s.connect(lo, pin);
    expect(s.state, PhoneState.noResponse);
  });

  test('sendAudio before connected sends nothing', () async {
    tv.answer = false;
    await s.connect(lo, pin);
    s.sendAudio(Uint8List(kFrameBytes));
    await wait(const Duration(milliseconds: 200));
    expect(tv.count(PacketType.audio), 0);
  });

  test('sendAudio is a 972 B datagram with the session pin', () async {
    await s.connect(lo, pin);
    await until(s, PhoneState.connected);
    s.beginTalk();
    s.sendAudio(Uint8List(kFrameBytes));
    await wait(const Duration(milliseconds: 200));
    final a = tv.received.firstWhere((p) => p.type == PacketType.audio);
    expect(a.pin, pin);
    expect(encodePacket(a).length, 972);
  });

  Future<List<int>> burst(SessionService svc, int n) async {
    svc.beginTalk();
    for (var i = 0; i < n; i++) {
      svc.sendAudio(Uint8List(kFrameBytes));
    }
    await wait(const Duration(milliseconds: 200));
    return [
      for (final p in tv.received)
        if (p.type == PacketType.audio) p.seq,
    ];
  }

  test("seq runs 0,1,2 and continues 3 after END (second burst)", () async {
    await s.connect(lo, pin);
    await until(s, PhoneState.connected);
    expect(await burst(s, 3), [0, 1, 2]);
    s.sendEnd();
    expect(await burst(s, 1), [0, 1, 2, 3]);
  });

  test("seq wraps 0xFFFFFFFF -> 0", () async {
    final s2 = SessionService(
      sender: sender,
      port: tv.port,
      initialSeq: 0xFFFFFFFF,
    );
    await s2.connect(lo, pin);
    await until(s2, PhoneState.connected);
    expect(await burst(s2, 2), [0xFFFFFFFF, 0]);
    await s2.disconnect();
  });

  test("after END an audio frame is not sent", () async {
    await s.connect(lo, pin);
    await until(s, PhoneState.connected);
    s.beginTalk();
    s.sendEnd();
    s.sendAudio(Uint8List(kFrameBytes));
    await wait(const Duration(milliseconds: 200));
    expect(tv.count(PacketType.audio), 0);
  });

  test('logs one line per second with the packets sent', () async {
    final lines = <String>[];
    final old = debugPrint;
    debugPrint = (m, {wrapWidth}) => lines.add(m ?? '');
    addTearDown(() => debugPrint = old);
    await s.connect(lo, pin);
    await until(s, PhoneState.connected);
    s.beginTalk();
    for (var i = 0; i < 3; i++) {
      s.sendAudio(Uint8List(kFrameBytes));
    }
    await wait(const Duration(milliseconds: 1400));
    expect(lines.where((l) => l.contains('sent=3 nextSeq=3')), hasLength(1));
  });
}
