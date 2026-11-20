import 'package:flutter_test/flutter_test.dart';
import 'package:lanmic_protocol/lanmic_protocol.dart';
import 'package:lanmic_tv/domain/receiver_status.dart';
import 'package:lanmic_tv/ui/features/receiver/view_models/stats_line.dart';

void main() {
  test('listening shows nothing', () {
    expect(statsLine(const ReceiverStatus(TvState.listening, rttMs: 9)), isEmpty);
  });

  test('connected shows Network only when the RTT is known', () {
    expect(statsLine(const ReceiverStatus(TvState.connected)), isEmpty);
    expect(statsLine(const ReceiverStatus(TvState.connected, rttMs: 9)), [
      ('Network', '9 ms', null),
    ]);
  });

  test('receiving with the full delay', () {
    const s = ReceiverStatus(
      TvState.receiving,
      delayMs: 140,
      tvDelayMs: 90,
      lostPermille: 3,
      band: WifiBand.ghz2_4,
    );
    expect(statsLine(s), [
      ('Delay', 'about 140 ms', Quality.ok),
      ('Lost audio', '0.3%', null),
      ('Wi-Fi', '2.4 GHz', null),
    ]);
    expect(
      statsSemantics(statsLine(s)),
      'Delay about 140 milliseconds, OK. Lost audio 0.3 percent. Wi-Fi 2.4 gigahertz.',
    );
  });

  test('old phone falls back to the TV delay; unknowns show a dash', () {
    const s = ReceiverStatus(TvState.receiving, tvDelayMs: 90);
    expect(statsLine(s), [
      ('TV delay', 'about 90 ms', null),
      ('Lost audio', '—', null),
      ('Wi-Fi', '—', null),
    ]);
  });
}
