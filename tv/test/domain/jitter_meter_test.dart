import 'package:flutter_test/flutter_test.dart';
import 'package:lanmic_tv/domain/jitter_meter.dart';

final t0 = DateTime.utc(2026, 1, 1);
DateTime at(int ms) => t0.add(Duration(milliseconds: ms));

void main() {
  test('unknown until two packets have arrived', () {
    final m = JitterMeter();
    expect(m.jitterMs, isNull);
    m.onAudio(0, at(0));
    expect(m.jitterMs, isNull);
    m.onAudio(1, at(10));
    expect(m.jitterMs, 0);
  });

  test('RFC 3550 estimator with a 1/16 gain', () {
    final m = JitterMeter()
      ..onAudio(0, at(0))
      ..onAudio(1, at(26)); // D = 26 - 10 = 16, J = 16 / 16
    expect(m.jitterMs, 1);
  });

  test('steady 10 ms spacing stays at 0; sequence gaps are not jitter', () {
    final m = JitterMeter()
      ..onAudio(0, at(0))
      ..onAudio(1, at(10))
      ..onAudio(5, at(50));
    expect(m.jitterMs, 0);
  });

  test('sequence numbers wrap at u32', () {
    final m = JitterMeter()
      ..onAudio(0xFFFFFFFF, at(0))
      ..onAudio(0, at(10));
    expect(m.jitterMs, 0);
  });

  test('restart forgets the previous arrival but keeps the estimate', () {
    final m = JitterMeter()
      ..onAudio(0, at(0))
      ..onAudio(1, at(26))
      ..restart()
      ..onAudio(50, at(5000)); // no previous arrival: no update
    expect(m.jitterMs, 1);
  });

  test('clear forgets everything', () {
    final m = JitterMeter()
      ..onAudio(0, at(0))
      ..onAudio(1, at(26))
      ..clear();
    expect(m.jitterMs, isNull);
  });
}
