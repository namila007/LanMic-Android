import 'package:flutter_test/flutter_test.dart';
import 'package:lanmic/domain/link_stats.dart';
import 'package:lanmic/ui/features/mic/view_models/stats_text.dart';
import 'package:lanmic_protocol/lanmic_protocol.dart';

void main() {
  test('formatters', () {
    expect(aboutMs(140), 'about 140 ms');
    expect(tildeMs(20), '~20 ms');
    expect(ms(9), '9 ms');
    expect(percent(3), '0.3%');
    expect(percent(0), '0.0%');
    expect(percent(125), '12.5%');
    expect(bandLabel(WifiBand.ghz2_4), '2.4 GHz');
    expect(bandLabel(WifiBand.ghz5), '5 GHz');
    expect(bandLabel(WifiBand.ghz6), '6 GHz');
    expect(bandLabel(WifiBand.unknown), '—');
    expect(qualityLabel(Quality.good), 'Good');
    expect(qualityLabel(Quality.ok), 'OK');
    expect(qualityLabel(Quality.slow), 'Slow');
  });

  test('statsSemantics reads the headline numbers', () {
    const l = LinkSnapshot(
      phoneMs: 40,
      rttMs: 9,
      delayMs: 140,
      lostPermille: 3,
      quality: Quality.ok,
    );
    expect(
      statsSemantics(l),
      'Delay about 140 milliseconds, OK. Network 9 milliseconds. Lost audio 0.3 percent.',
    );
  });
}
