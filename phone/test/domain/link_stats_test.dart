import 'package:flutter_test/flutter_test.dart';
import 'package:lanmic/domain/link_stats.dart';
import 'package:lanmic_protocol/lanmic_protocol.dart';

Duration ms(int v) => Duration(milliseconds: v);

void main() {
  late LinkStats s;
  setUp(() => s = LinkStats(phoneMs: 40)..reset(Duration.zero));

  test('no samples: everything unknown, no quality', () {
    final v = s.snapshot(ms(100));
    expect(v.rttMs, isNull);
    expect(v.wifiMs, isNull);
    expect(v.tvMs, isNull);
    expect(v.delayMs, isNull);
    expect(v.quality, isNull);
    expect(v.phoneMs, 40);
    expect(v.tvBand, WifiBand.unknown);
    expect(s.helloInfo, (rttMs: null, delayMs: null));
  });

  test('RTT is the matching ACK time, mean of the last 5 samples', () {
    for (var i = 0; i < 6; i++) {
      s.helloSent(i, ms(i * 2000));
      s.ackReceived(i, ms(i * 2000 + (i == 0 ? 100 : 10)));
    }
    final v = s.snapshot(ms(12000));
    expect(v.rttMs, 10); // the 100 ms sample has left the window
    expect(v.wifiMs, 5);
  });

  test('ACK for an unknown or already-answered ping is ignored', () {
    s.helloSent(1, ms(0));
    s.ackReceived(2, ms(5));
    expect(s.snapshot(ms(10)).rttMs, isNull);
    s.ackReceived(1, ms(8));
    s.ackReceived(1, ms(900));
    expect(s.snapshot(ms(1000)).rttMs, 8);
  });

  test('ping ids wrap at u32', () {
    s.helloSent(0xFFFFFFFF, ms(0));
    s.ackReceived(0xFFFFFFFF, ms(6));
    s.helloSent(0, ms(2000));
    s.ackReceived(0, ms(2010));
    expect(s.snapshot(ms(3000)).rttMs, 8);
  });

  test('only the last 5 pending pings are remembered', () {
    for (var i = 0; i < 6; i++) {
      s.helloSent(i, ms(i));
    }
    s.ackReceived(0, ms(50)); // evicted
    expect(s.snapshot(ms(60)).rttMs, isNull);
    s.ackReceived(5, ms(15));
    expect(s.snapshot(ms(60)).rttMs, 10);
  });

  test('delay = phone + RTT/2 + TV, with the quality word', () {
    s.helloSent(0, ms(0));
    s.ackReceived(0, ms(10));
    s.statsReceived(
      const StatsReport(
        tvDelayMs: 115,
        lostPermille: 3,
        jitterMs: 3,
        band: WifiBand.ghz5,
      ),
    );
    final v = s.snapshot(ms(100));
    expect(v.tvMs, 115);
    expect(v.delayMs, 160);
    expect(v.lostPermille, 3);
    expect(v.jitterMs, 3);
    expect(v.tvBand, WifiBand.ghz5);
    expect(v.quality, Quality.ok);
    expect(s.helloInfo, (rttMs: 10, delayMs: 160));
  });

  test('unknown TV fields (band too) keep the last known value', () {
    s.helloSent(0, ms(0));
    s.ackReceived(0, ms(10));
    s.statsReceived(
      const StatsReport(
        tvDelayMs: 115,
        lostPermille: 3,
        jitterMs: 3,
        band: WifiBand.ghz5,
      ),
    );
    s.statsReceived(const StatsReport(band: WifiBand.ghz2_4));
    s.statsReceived(const StatsReport()); // TV sends the band only at first
    final v = s.snapshot(ms(100));
    expect(v.tvMs, 115);
    expect(v.lostPermille, 3);
    expect(v.jitterMs, 3);
    expect(v.tvBand, WifiBand.ghz2_4);
  });

  test('no STATS 3 s after the first ACK means the TV app is too old', () {
    expect(s.snapshot(ms(60000)).tvTooOld, isFalse); // no ACK yet: nothing to judge
    s.helloSent(0, ms(1000));
    s.ackReceived(0, ms(1010));
    expect(s.snapshot(ms(4009)).tvTooOld, isFalse);
    expect(s.snapshot(ms(4010)).tvTooOld, isTrue);
    s.statsReceived(const StatsReport());
    expect(s.snapshot(ms(6000)).tvTooOld, isFalse);
  });

  test('reset clears everything and restarts the old-TV clock', () {
    s.helloSent(0, ms(0));
    s.ackReceived(0, ms(10));
    s.statsReceived(const StatsReport(tvDelayMs: 115));
    s.reset(ms(10000));
    final v = s.snapshot(ms(11000));
    expect(v.rttMs, isNull);
    expect(v.tvMs, isNull);
    expect(v.tvTooOld, isFalse);
    expect(s.snapshot(ms(20000)).tvTooOld, isFalse); // clock starts at the next ACK
    s.helloSent(1, ms(20000));
    s.ackReceived(1, ms(20005));
    expect(s.snapshot(ms(23005)).tvTooOld, isTrue);
  });

  test('RTT keeps sub-millisecond precision before rounding', () {
    s.helloSent(0, ms(0));
    s.ackReceived(0, const Duration(microseconds: 4600));
    s.helloSent(1, ms(2000));
    s.ackReceived(1, const Duration(microseconds: 2004600));
    expect(s.snapshot(ms(3000)).rttMs, 5);
  });

  test('before any reset nothing is reported as too old', () {
    expect(LinkStats().snapshot(ms(60000)).tvTooOld, isFalse);
  });

  test('default phone part is the per-build estimate', () {
    expect(LinkStats().snapshot(Duration.zero).phoneMs, kPhoneDelayEstimateMs);
  });
}
