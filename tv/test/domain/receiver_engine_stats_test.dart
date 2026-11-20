
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanmic_protocol/lanmic_protocol.dart';
import 'package:lanmic_tv/domain/receiver_status.dart';
import 'package:lanmic_tv/domain/session_registry.dart';

import '../support/engine_rig.dart';

const _tenMs = Duration(milliseconds: 10);

List<(StatsReport, Peer)> statsSent(Rig r) => [
  for (final (bytes, to) in r.port.sent)
    if (decodePacket(bytes)!.type == PacketType.stats)
      (decodePacket(bytes)!.statsReport!, to),
];

/// One audio frame per 10 ms for [frames] frames, as a phone would send.
int stream(Rig r, int frames, {int seq = 1, Peer from = a}) {
  for (var i = 0; i < frames; i++) {
    r.audio(seq++, from);
    r.async.elapse(_tenMs);
  }
  return seq;
}

void main() {
  rig('sends one STATS per second to the active phone only', (r) {
    r.hello();
    r.rx(Packet.hello(1, 1), b); // wrong PIN: rejected, never active
    r.async.elapse(const Duration(milliseconds: 1050));
    expect(statsSent(r).map((s) => s.$2), [a]);
    r.async.elapse(const Duration(seconds: 1));
    expect(statsSent(r).map((s) => s.$2), [a, a]);
  });

  rig('band is in the first 3 STATS to a phone, unknown afterwards; a new '
      'phone gets it again', (r) {
    r.hello();
    r.async.elapse(const Duration(milliseconds: 5050));
    expect(statsSent(r).map((s) => s.$1.band), [
      WifiBand.ghz5,
      WifiBand.ghz5,
      WifiBand.ghz5,
      WifiBand.unknown,
      WifiBand.unknown,
    ]);
    r.hello(b);
    r.async.elapse(const Duration(seconds: 1));
    final last = statsSent(r).last;
    expect(last.$2, b);
    expect(last.$1.band, WifiBand.ghz5);
  });

  rig('STATS carries tvDelayMs from depth and sink latency', (r) {
    r.sink.latencyMs = 30;
    r.hello();
    stream(r, 120);
    final report = statsSent(r).last.$1;
    expect(report.tvDelayMs, inInclusiveRange(40, 70));
    expect(r.engine.current.tvDelayMs, report.tvDelayMs);
  });

  rig('gap and underrun count as lost', (r) {
    r.hello();
    for (final s in [1, 2, 4]) {
      r.audio(s); // 3 never arrives
    }
    r.ticks(1); // starts the sink
    r.async.flushMicrotasks();
    r.ticks(5); // voice, voice, gap, voice, underrun
    expect(r.engine.loss.lostPermille(r.now()), 400);
  });

  rig('an underrun 100 ms after the last audio does not count', (r) {
    r.hello();
    for (var s = 1; s <= 3; s++) {
      r.audio(s);
    }
    r.async.elapse(const Duration(milliseconds: 300));
    final before = r.engine.loss.lostPermille(r.now());
    expect(before, isNotNull);
    r.async.elapse(const Duration(milliseconds: 150));
    expect(r.engine.loss.lostPermille(r.now()), before);
  });

  rig('discarded frames count as lost', (r) {
    r.hello();
    for (var s = 1; s <= 9; s++) {
      r.audio(s); // 9 > maxDepth: 6 trimmed
    }
    expect(r.engine.loss.lostPermille(r.now()), 1000);
  });

  rig('native-dropped frames count as lost', (r) {
    r.hello();
    stream(r, 60);
    expect(r.engine.loss.lostPermille(r.now()), 0);
    r.sink.dropped = 50;
    stream(r, 60, seq: 61); // the 1 s housekeeping reads the 50 drops
    expect(r.engine.loss.lostPermille(r.now()), 299);
    expect(r.engine.current.lostPermille, 342); // cached at the 1 s tick
  });

  rig('new phone clears tvDelayMs, loss and jitter', (r) {
    r.sink.latencyMs = 30;
    r.hello();
    stream(r, 110);
    expect(r.engine.current.tvDelayMs, isNotNull);
    expect(r.engine.current.lostPermille, isNotNull);
    expect(r.engine.jitter.jitterMs, isNotNull);
    r.hello(b);
    expect(r.engine.current.tvDelayMs, isNull);
    expect(r.engine.current.lostPermille, isNull);
    expect(r.engine.jitter.jitterMs, isNull);
  });

  rig('tvDelayMs is the mean of the last 5 samples and is kept after the '
      'burst', (r) {
    var seq = 1;
    for (final l in [100, 10, 20, 30, 40, 55]) {
      r.sink.latencyMs = l;
      r.hello();
      seq = stream(r, 100, seq: seq);
    }
    final tv = r.engine.current.tvDelayMs!;
    expect(tv, inInclusiveRange(31, 71));
    expect((tv - 31) % 10, 0); // 31 = mean(10, 20, 30, 40, 55); depth adds whole 10s
    r.hello();
    r.async.elapse(const Duration(seconds: 2)); // burst over, phone still active
    expect(r.engine.current.state, TvState.connected);
    expect(r.engine.current.tvDelayMs, tv);
  });

  rig('a same-phone reconnect gets the band again', (r) {
    r.hello();
    r.async.elapse(const Duration(milliseconds: 4050));
    expect(statsSent(r).map((s) => s.$1.band).last, WifiBand.unknown);
    r.async.elapse(const Duration(seconds: 7)); // phone times out
    final n = statsSent(r).length;
    r.hello();
    r.async.elapse(const Duration(milliseconds: 1050));
    expect(statsSent(r).length, n + 1);
    expect(statsSent(r).last.$1.band, WifiBand.ghz5);
  });

  test('onPhoneActive fires once per new phone', () {
    var n = 0;
    fakeAsync((async) {
      final r = Rig(async, onPhoneActive: () => n++);
      r.hello();
      r.hello();
      expect(n, 1);
      r.hello(b);
      expect(n, 2);
    });
  });

  rig('status carries phone rttMs/delayMs from HELLO; old phone leaves them '
      'null', (r) {
    r.hello(a, (rttMs: 9, delayMs: 140));
    expect(r.engine.current.rttMs, 9);
    expect(r.engine.current.delayMs, 140);
    r.hello(b);
    expect(r.engine.current.rttMs, isNull);
    expect(r.engine.current.delayMs, isNull);
  });
}
