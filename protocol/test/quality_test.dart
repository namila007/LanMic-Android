import 'package:lanmic_protocol/lanmic_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('unknown delay gives no quality word', () {
    expect(qualityOf(delayMs: null, lostPermille: 0), isNull);
  });

  test('Good needs delay < 100 ms and loss < 1%', () {
    expect(qualityOf(delayMs: 99, lostPermille: 9), Quality.good);
    expect(qualityOf(delayMs: 99), Quality.good); // unknown loss counts as 0
    expect(qualityOf(delayMs: 100, lostPermille: 0), Quality.ok);
    expect(qualityOf(delayMs: 50, lostPermille: 10), Quality.ok);
  });

  test('Slow at delay >= 200 ms or loss >= 5%', () {
    expect(qualityOf(delayMs: 199, lostPermille: 49), Quality.ok);
    expect(qualityOf(delayMs: 200), Quality.slow);
    expect(qualityOf(delayMs: 20, lostPermille: 50), Quality.slow);
  });
}
