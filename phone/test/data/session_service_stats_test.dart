import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanmic/data/services/session_service.dart';
import 'package:lanmic/data/services/udp_sender.dart';
import 'package:lanmic/domain/phone_state.dart';
import 'package:lanmic_protocol/lanmic_protocol.dart';

class _FakeSender implements UdpSender {
  final sent = <Packet>[];
  final _in = StreamController<Incoming>.broadcast(sync: true);
  @override
  Stream<Incoming> get incoming => _in.stream;
  @override
  void send(Uint8List bytes, InternetAddress to, int port) =>
      sent.add(decodePacket(bytes)!);
  void receive(Packet p, {InternetAddress? from, int port = kPort}) =>
      _in.add((packet: p, from: from ?? tv, port: port));
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

final tv = InternetAddress('192.168.1.5');
const pin = 482917;

void main() {
  late _FakeSender sender;
  late SessionService s;

  void setUpService(FakeAsync a) {
    sender = _FakeSender();
    final start = DateTime(2026);
    s = SessionService(
      sender: sender,
      now: () => start.add(a.elapsed),
      elapsed: () => a.elapsed,
    );
  }

  List<Packet> hellos() =>
      sender.sent.where((p) => p.type == PacketType.hello).toList();

  test('HELLO seq increments and the ACK echo yields rttMs', () {
    fakeAsync((a) {
      setUpService(a);
      s.connect(tv, pin);
      expect(hellos().single.seq, 1);
      a.elapse(const Duration(milliseconds: 12));
      sender.receive(Packet.ack(1, pin, 'TV'));
      expect(s.link.rttMs, 12);
      a.elapse(const Duration(seconds: 3));
      expect(hellos().last.seq, 2);
    });
  });

  test('STATS with a wrong PIN or from another port is ignored', () {
    fakeAsync((a) {
      setUpService(a);
      s.connect(tv, pin);
      sender.receive(Packet.stats(0, pin + 1, const StatsReport(tvDelayMs: 50)));
      sender.receive(
        Packet.stats(0, pin, const StatsReport(tvDelayMs: 60)),
        port: 1,
      );
      expect(s.link.tvMs, isNull);
      sender.receive(Packet.stats(0, pin, const StatsReport(tvDelayMs: 70)));
      expect(s.link.tvMs, 70);
    });
  });

  test('connect again resets link', () {
    fakeAsync((a) {
      setUpService(a);
      s.connect(tv, pin);
      a.elapse(const Duration(milliseconds: 5));
      sender.receive(Packet.ack(1, pin, 'TV'));
      a.elapse(const Duration(seconds: 4));
      expect(s.link.tvTooOld, isTrue);
      s.connect(tv, pin);
      expect(s.link.rttMs, isNull);
      expect(s.link.tvTooOld, isFalse);
    });
  });

  test('HELLO after STATS carries delayMs', () {
    fakeAsync((a) {
      setUpService(a);
      s.connect(tv, pin);
      a.elapse(const Duration(milliseconds: 10));
      sender.receive(Packet.ack(1, pin, 'TV'));
      sender.receive(Packet.stats(0, pin, const StatsReport(tvDelayMs: 100)));
      a.elapse(const Duration(seconds: 3));
      // 40 phone + 5 wifi + 100 tv
      expect(hellos().last.helloInfo, (rttMs: 10, delayMs: 145));
    });
  });

  test('linkUpdates emits once per second while connected', () {
    fakeAsync((a) {
      setUpService(a);
      var n = 0;
      s.linkUpdates.listen((_) => n++);
      s.connect(tv, pin);
      sender.receive(Packet.ack(1, pin, 'TV'));
      expect(s.state, PhoneState.connected);
      a.elapse(const Duration(seconds: 1));
      expect(n, 1);
      a.elapse(const Duration(milliseconds: 1000));
      expect(n, 2);
      s.disconnect();
    });
  });
}
