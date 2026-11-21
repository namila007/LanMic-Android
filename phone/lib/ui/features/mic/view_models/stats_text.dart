import 'package:lanmic/domain/link_stats.dart';
import 'package:lanmic_protocol/lanmic_protocol.dart';

String aboutMs(int v) => 'about $v ms';
String tildeMs(int v) => '~$v ms';
String ms(int v) => '$v ms';

/// [permille] in, one decimal out: 3 -> '0.3%'.
String percent(int permille) => '${(permille / 10).toStringAsFixed(1)}%';

String bandLabel(WifiBand b) => switch (b) {
  WifiBand.ghz2_4 => '2.4 GHz',
  WifiBand.ghz5 => '5 GHz',
  WifiBand.ghz6 => '6 GHz',
  WifiBand.unknown => '—',
};

String qualityLabel(Quality q) => switch (q) {
  Quality.good => 'Good',
  Quality.ok => 'OK',
  Quality.slow => 'Slow',
};

String statsSemantics(LinkSnapshot l) {
  final q = l.quality;
  return [
    if (l.delayMs != null)
      'Delay about ${l.delayMs} milliseconds${q == null ? '' : ', ${qualityLabel(q)}'}.',
    if (l.rttMs != null) 'Network ${l.rttMs} milliseconds.',
    if (l.lostPermille != null)
      'Lost audio ${(l.lostPermille! / 10).toStringAsFixed(1)} percent.',
  ].join(' ');
}

/// Voice gain with a real minus sign: 0 -> '0 dB', 3 -> '+3 dB', -6 -> '−6 dB'.
String dbText(int db) => db == 0 ? '0 dB' : '${db > 0 ? '+' : '−'}${db.abs()} dB';

/// For screen readers: 3 -> 'plus 3 decibels'.
String dbSpoken(int db) => '${db > 0
    ? 'plus '
    : db < 0
    ? 'minus '
    : ''}${db.abs()} decibels';
