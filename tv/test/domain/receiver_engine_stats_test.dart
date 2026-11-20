import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanmic_protocol/lanmic_protocol.dart';
import 'package:lanmic_tv/domain/audio_engine.dart';
import 'package:lanmic_tv/domain/session_registry.dart';

import '../support/engine_rig.dart';

List<(StatsReport, Peer)> statsSent(Rig r) => [
  for (final (bytes, to) in r.audio.sent)
    if (decodePacket(bytes)!.type == PacketType.stats)
      (decodePacket(bytes)!.statsReport!, to),
];

AudioStats audio({
  int played = 0,
  int lost = 0,
  int discarded = 0,
  int depth = 20,
  int? latency = 30,
  int jitter = 3,
  int age = 10,
}) => AudioStats(
  played: played,
  lost: lost,
  discarded: discarded,
  depthMs: depth,
  latencyMs: latency,
  jitterMs: jitter,
  lastAudioAgeMs: age,
);

void main() {
  rig('STATS once a second to the active phone with the native jitter; band only in the first 3', (r) {
    r.hello();
    r.rx(Packet.hello(1, 1), b); // wrong PIN: rejected, never active
    r.audio.statsValue = audio(jitter: 7);
    r.async.elapse(const Duration(milliseconds: 5050));
    final s = statsSent(r);
    expect(s.map((e) => e.$2), [a, a, a, a, a]);
    expect(s.map((e) => e.$1.band), [
      WifiBand.ghz5,
      WifiBand.ghz5,
      WifiBand.ghz5,
      WifiBand.unknown,
      WifiBand.unknown,
    ]);
    expect(s.last.$1.jitterMs, 7);
  });

  rig('a new phone gets the band again and clears its numbers', (r) {
    r.hello();
    r.audio.statsValue = audio();
    r.async.elapse(const Duration(seconds: 5));
    expect(r.engine.current.tvDelayMs, isNotNull);
    r.hello(b);
    expect(r.engine.current.tvDelayMs, isNull);
    expect(r.engine.current.lostPermille, isNull);
    r.async.elapse(const Duration(milliseconds: 1000));
    final last = statsSent(r).last;
    expect(last.$2, b);
    expect(last.$1.band, WifiBand.ghz5);
  });

  rig('loss deltas feed LossMeter; a native counter reset rebaselines', (r) {
    r.hello();
    r.audio.statsValue = audio();
    r.async.elapse(const Duration(seconds: 1)); // baseline
    r.audio.statsValue = audio(played: 90, lost: 10);
    r.async.elapse(const Duration(seconds: 1));
    expect(r.engine.loss.lostPermille(r.now()), 100);
    r.audio.statsValue = audio(played: 5, lost: 0); // native restarted
    r.async.elapse(const Duration(seconds: 1));
    expect(r.engine.loss.lostPermille(r.now()), 100); // unchanged, not negative
    r.audio.statsValue = audio(played: 105, lost: 0);
    r.async.elapse(const Duration(seconds: 1));
    expect(r.engine.loss.lostPermille(r.now()), lessThan(100));
  });

  rig('discarded frames count as lost', (r) {
    r.hello();
    r.audio.statsValue = audio();
    r.async.elapse(const Duration(seconds: 1));
    r.audio.statsValue = audio(played: 90, discarded: 10);
    r.async.elapse(const Duration(seconds: 1));
    expect(r.engine.loss.lostPermille(r.now()), 100);
  });

  rig('tvDelayMs = mean of the last 5 (depth + latency) while receiving, kept after the burst', (r) {
    r.hello();
    for (final depth in [100, 10, 20, 30, 40, 50]) {
      r.audio.statsValue = audio(depth: depth, latency: 5);
      r.async.elapse(const Duration(seconds: 1));
    }
    // mean(10, 20, 30, 40, 50) + 5
    expect(r.engine.current.tvDelayMs, 35);
    r.audio.statsValue = audio(age: 900); // burst over, phone still active
    r.async.elapse(const Duration(seconds: 2));
    expect(r.engine.current.tvDelayMs, 35);
    expect(r.engine.current.lostPermille, anyOf(isNull, isNonNegative));
  });

  rig('a same-phone reconnect gets the band again', (r) {
    r.hello();
    r.async.elapse(const Duration(milliseconds: 4050));
    expect(statsSent(r).last.$1.band, WifiBand.unknown);
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

  rig('status carries phone rttMs/delayMs from HELLO; old phone leaves them null', (r) {
    r.hello(a, (rttMs: 9, delayMs: 140));
    expect(r.engine.current.rttMs, 9);
    expect(r.engine.current.delayMs, 140);
    r.hello(b);
    expect(r.engine.current.rttMs, isNull);
    expect(r.engine.current.delayMs, isNull);
  });
}
