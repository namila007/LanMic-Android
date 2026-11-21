import 'package:flutter_test/flutter_test.dart';
import 'package:lanmic_protocol/lanmic_protocol.dart';
import 'package:lanmic_tv/domain/receiver_status.dart';

void main() {
  test('toMap/fromMap round-trips every state', () {
    for (final s in TvState.values) {
      final st = ReceiverStatus(s, framesRx: 5, framesDropped: 2, underruns: 1);
      expect(ReceiverStatus.fromMap(st.toMap()), st);
    }
  });

  test('unknown state falls back to listening', () {
    expect(ReceiverStatus.fromMap({'state': 'bogus'}).state, TvState.listening);
  });

  test('map round-trips the stats fields', () {
    const st = ReceiverStatus(
      TvState.receiving,
      rttMs: 9,
      delayMs: 140,
      tvDelayMs: 90,
      lostPermille: 3,
      band: WifiBand.ghz5,
      gainLimiting: true,
    );
    expect(ReceiverStatus.fromMap(st.toMap()), st);
    expect(ReceiverStatus.fromMap({'state': 'receiving'}).band, WifiBand.unknown);
  });
}
