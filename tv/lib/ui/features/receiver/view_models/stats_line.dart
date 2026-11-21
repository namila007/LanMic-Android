import 'package:lanmic_protocol/lanmic_protocol.dart';

import '../../../../domain/receiver_status.dart';

typedef StatItem = (String label, String value, Quality? quality);

String qualityLabel(Quality q) => switch (q) {
  Quality.good => 'Good',
  Quality.ok => 'OK',
  Quality.slow => 'Slow',
};

String _band(WifiBand b) => switch (b) {
  WifiBand.ghz2_4 => '2.4 GHz',
  WifiBand.ghz5 => '5 GHz',
  WifiBand.ghz6 => '6 GHz',
  WifiBand.unknown => '—',
};

/// What the TV shows under the status row, per state.
List<StatItem> statsLine(ReceiverStatus s) {
  switch (s.state) {
    case TvState.listening:
      return const [];
    case TvState.connected:
      final rtt = s.rttMs;
      return rtt == null ? const [] : [('Network', '$rtt ms', null)];
    case TvState.receiving:
      final lost = s.lostPermille;
      return [
        if (s.delayMs != null)
          (
            'Delay',
            'about ${s.delayMs} ms',
            qualityOf(delayMs: s.delayMs, lostPermille: lost),
          )
        else if (s.tvDelayMs != null)
          ('TV delay', 'about ${s.tvDelayMs} ms', null),
        ('Lost audio', lost == null ? '—' : '${(lost / 10).toStringAsFixed(1)}%', null),
        ('Wi-Fi', _band(s.band), null),
      ];
  }
}

/// Screen-reader text: 'Delay about 140 milliseconds, OK. Lost audio 0.3 percent. ...'
String statsSemantics(List<StatItem> items) => items
    .map((i) {
      final v = i.$2
          .replaceAll(' ms', ' milliseconds')
          .replaceAll('%', ' percent')
          .replaceAll(' GHz', ' gigahertz')
          .replaceAll('—', 'unknown');
      final q = i.$3;
      return '${i.$1} $v${q == null ? '' : ', ${qualityLabel(q)}'}.';
    })
    .join(' ');

/// Voice gain with a real minus sign: 0 -> '0 dB', 3 -> '+3 dB', -6 -> '−6 dB'.
String dbText(int db) => db == 0 ? '0 dB' : '${db > 0 ? '+' : '−'}${db.abs()} dB';

/// Screen-reader text: 'Voice volume plus 3 decibels. Voice limited.'
String voiceSemantics(int db, {bool limited = false}) =>
    'Voice volume ${db > 0
        ? 'plus '
        : db < 0
        ? 'minus '
        : ''}${db.abs()} decibels.${limited ? ' Voice limited.' : ''}';
