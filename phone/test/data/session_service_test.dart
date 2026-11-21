
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanmic/data/services/session_service.dart';
import 'package:lanmic/domain/phone_state.dart';
import 'package:lanmic_protocol/lanmic_protocol.dart';

import '../support/fake_tv.dart';

const pin = 482917;

void main() {
  late FakeTv tv;
  late SessionService s;
  late List<String> targets;
  late List<String> order; // setTarget and END, in call order

  void setUpService(FakeAsync a, {FakeTv? withTv}) {
    tv = withTv ?? FakeTv();
    targets = [];
    order = [];
    final start = DateTime(2026);
    s = SessionService(
      port: tv,
      setTarget: (h, p, n) async {
        targets.add('$h:$p:$n');
        order.add('target');
      },
      now: () => start.add(a.elapsed),
      elapsed: () => a.elapsed,
    );
  }

  test('connected sets the target; lost and disconnected clear it', () {
    fakeAsync((a) {
      setUpService(a);
      s.connect(tvAddress, pin);
      a.flushMicrotasks();
      expect(s.state, PhoneState.connected);
      expect(targets.last, '192.168.1.5:5004:$pin');
      tv.answer = false;
      a.elapse(const Duration(seconds: 7));
      expect(s.state, PhoneState.lost);
      expect(targets.last, 'null:0:0');
      tv.answer = true;
      a.elapse(const Duration(seconds: 3));
      expect(s.state, PhoneState.connected);
      expect(targets.last, '192.168.1.5:5004:$pin');
      s.disconnect();
      expect(targets.last, 'null:0:0');
    });
  });

  test('wrong PIN -> wrongPin, target never set', () {
    fakeAsync((a) {
      setUpService(a);
      s.connect(tvAddress, 111111);
      a.flushMicrotasks();
      expect(s.state, PhoneState.wrongPin);
      expect(targets.where((t) => t != 'null:0:0'), isEmpty);
    });
  });

  test('no answer -> noResponse after 3 HELLOs at 3 s', () {
    fakeAsync((a) {
      setUpService(a, withTv: FakeTv(answer: false));
      s.connect(tvAddress, pin);
      a.elapse(const Duration(milliseconds: 2900));
      expect(s.state, PhoneState.connecting);
      a.elapse(const Duration(milliseconds: 300));
      expect(s.state, PhoneState.noResponse);
      expect(tv.count(PacketType.hello), 3);
    });
  });

  test('rebind clears target, HELLO now, target back on ACK', () {
    fakeAsync((a) {
      setUpService(a);
      s.connect(tvAddress, pin);
      a.flushMicrotasks();
      final hellos = tv.count(PacketType.hello);
      tv.answer = false;
      tv.bound(43211); // the socket was rebound: new source port
      a.flushMicrotasks();
      expect(tv.count(PacketType.hello), hellos + 1); // announced at once
      expect(targets.last, 'null:0:0'); // no audio from the unannounced port
      tv.receive(Packet.ack(tv.sent.last.seq, pin, 'TV'));
      a.flushMicrotasks();
      expect(s.state, PhoneState.connected);
      expect(targets.last, '192.168.1.5:5004:$pin');
    });
  });

  test('rebind while talking keeps the session live and re-targets on ACK', () {
    fakeAsync((a) {
      setUpService(a);
      final states = <PhoneState>[];
      s.states.listen(states.add);
      s.connect(tvAddress, pin);
      a.flushMicrotasks();
      states.clear();
      tv.bound(43211);
      a.flushMicrotasks();
      expect(states, isEmpty); // never left connected: a Keep talk is not closed
      expect(s.state, PhoneState.connected);
      expect(targets.last, '192.168.1.5:5004:$pin'); // the fake TV ACKed at once
      expect(targets.where((t) => t == 'null:0:0'), isNotEmpty); // cleared in between
    });
  });

  test('HELLO send failure while idle triggers one rebind', () {
    fakeAsync((a) {
      setUpService(a, withTv: FakeTv()..failSends = true);
      s.connect(tvAddress, pin);
      a.flushMicrotasks();
      s.endSender()();
      a.flushMicrotasks();
      expect(tv.rebinds, 1); // not one per failed send
      tv.bound(40001); // the new socket re-arms it
      s.endSender()();
      a.flushMicrotasks();
      expect(tv.rebinds, 2);
    });
  });

  test('a setTarget failure is reported as a send failure', () {
    fakeAsync((a) {
      final t = FakeTv();
      final start = DateTime(2026);
      s = SessionService(
        port: t,
        setTarget: (h, p, n) async => throw StateError('jni'),
        now: () => start.add(a.elapsed),
        elapsed: () => a.elapsed,
      );
      s.connect(tvAddress, pin);
      a.flushMicrotasks();
      expect(s.state, PhoneState.lost);
    });
  });

  test('END goes to the TV and PIN of the moment it was scheduled', () {
    fakeAsync((a) {
      setUpService(a, withTv: FakeTv(answer: false));
      s.connect(tvAddress, pin);
      final end = s.endSender();
      s.disconnect();
      s.connect(tvAddress, 111111);
      end();
      a.flushMicrotasks();
      expect(tv.sent.last.type, PacketType.end);
      expect(tv.sent.last.pin, pin);
    });
  });

  test('a bound event before connect or after disconnect sends nothing', () {
    fakeAsync((a) {
      setUpService(a);
      tv.bound(40000);
      expect(tv.sent, isEmpty);
      s.connect(tvAddress, pin);
      a.flushMicrotasks();
      s.disconnect();
      final n = tv.sent.length;
      tv.bound(40001);
      expect(tv.sent.length, n);
    });
  });

  test('send failure -> noResponse, no exception', () {
    fakeAsync((a) {
      setUpService(a, withTv: FakeTv()..failSends = true);
      s.connect(tvAddress, pin);
      a.flushMicrotasks();
      expect(s.state, PhoneState.noResponse);
    });
  });

  test('ACK from another port or after disconnect is ignored', () {
    fakeAsync((a) {
      setUpService(a, withTv: FakeTv(answer: false));
      s.connect(tvAddress, pin);
      tv.receive(Packet.ack(1, pin, 'Evil'), port: 1);
      expect(s.state, PhoneState.connecting);
      s.disconnect();
      tv.receive(Packet.ack(1, pin, 'x'));
      expect(s.state, PhoneState.disconnected);
    });
  });

  test('sendEnd sends END with the session pin', () {
    fakeAsync((a) {
      setUpService(a);
      s.connect(tvAddress, pin);
      s.endSender()();
      a.flushMicrotasks();
      expect(tv.sent.last.type, PacketType.end);
      expect(tv.sent.last.pin, pin);
    });
  });

  test('HELLO seq increments and the ACK echo yields rttMs', () {
    fakeAsync((a) {
      setUpService(a, withTv: FakeTv(answer: false));
      s.connect(tvAddress, pin);
      expect(tv.sent.single.seq, 1);
      a.elapse(const Duration(milliseconds: 12));
      tv.receive(Packet.ack(1, pin, 'TV'));
      expect(s.link.rttMs, 12);
      a.elapse(const Duration(seconds: 3));
      expect(tv.sent.last.seq, 2);
    });
  });

  test('STATS with a wrong PIN or from another port is ignored', () {
    fakeAsync((a) {
      setUpService(a, withTv: FakeTv(answer: false));
      s.connect(tvAddress, pin);
      tv.receive(Packet.stats(0, pin + 1, const StatsReport(tvDelayMs: 50)));
      tv.receive(Packet.stats(0, pin, const StatsReport(tvDelayMs: 60)), port: 1);
      expect(s.link.tvMs, isNull);
      tv.receive(Packet.stats(0, pin, const StatsReport(tvDelayMs: 70)));
      expect(s.link.tvMs, 70);
    });
  });

  test('connect again resets link', () {
    fakeAsync((a) {
      setUpService(a, withTv: FakeTv(answer: false));
      s.connect(tvAddress, pin);
      a.elapse(const Duration(milliseconds: 5));
      tv.receive(Packet.ack(1, pin, 'TV'));
      a.elapse(const Duration(seconds: 4));
      expect(s.link.tvTooOld, isTrue);
      s.connect(tvAddress, pin);
      expect(s.link.rttMs, isNull);
      expect(s.link.tvTooOld, isFalse);
    });
  });

  test('HELLO after STATS carries delayMs from the measured phone latency', () {
    fakeAsync((a) {
      setUpService(a, withTv: FakeTv(answer: false));
      s.connect(tvAddress, pin);
      a.elapse(const Duration(milliseconds: 10));
      tv.receive(Packet.ack(1, pin, 'TV'));
      tv.receive(Packet.stats(0, pin, const StatsReport(tvDelayMs: 100)));
      a.elapse(const Duration(seconds: 3));
      final hellos = tv.sent.where((p) => p.type == PacketType.hello).toList();
      expect(hellos.last.helloInfo, (rttMs: 10, delayMs: 145)); // 40 + 5 + 100
      s.setPhoneLatency(12);
      a.elapse(const Duration(seconds: 3));
      expect(tv.sent.where((p) => p.type == PacketType.hello).last.helloInfo,
          (rttMs: 10, delayMs: 122)); // 12 + 5 + 5 + 100
    });
  });

  test('linkUpdates emits once per second while connected', () {
    fakeAsync((a) {
      setUpService(a);
      var n = 0;
      s.linkUpdates.listen((_) => n++);
      s.connect(tvAddress, pin);
      expect(s.state, PhoneState.connected);
      a.elapse(const Duration(seconds: 1));
      expect(n, 1);
      a.elapse(const Duration(seconds: 1));
      expect(n, 2);
      s.disconnect();
    });
  });
}
