import 'package:lanmic_protocol/lanmic_protocol.dart';

const kPhoneDelayEstimateMs = 40; // shortcut: half the ~80 ms `record` chunk; replace with a measured value in the native-capture work
const _window = 5;
const _tooOldAfter = Duration(seconds: 3);

class LinkSnapshot {
  const LinkSnapshot({
    this.rttMs,
    this.wifiMs,
    this.tvMs,
    this.delayMs,
    this.lostPermille,
    this.jitterMs,
    required this.phoneMs,
    this.tvBand = WifiBand.unknown,
    this.quality,
    this.tvTooOld = false,
  });
  final int? rttMs, wifiMs, tvMs, delayMs, lostPermille, jitterMs;
  final int phoneMs;
  final WifiBand tvBand;
  final Quality? quality;
  final bool tvTooOld;
}

/// RTT from HELLO/ACK pings plus what the TV reports; adds up the total delay.
class LinkStats {
  LinkStats({this.phoneMs = kPhoneDelayEstimateMs});
  final int phoneMs;

  final _pending = <int, Duration>{}; // insertion-ordered
  final _rtts = <int>[]; // microseconds
  StatsReport _tv = const StatsReport();
  Duration? _firstAckAt; // the old-TV clock starts at the first ACK, not at connect
  bool _gotStats = false;

  void reset(Duration now) {
    _pending.clear();
    _rtts.clear();
    _tv = const StatsReport();
    _firstAckAt = null;
    _gotStats = false;
  }

  void helloSent(int pingId, Duration now) {
    _pending.remove(pingId);
    _pending[pingId] = now;
    if (_pending.length > _window) _pending.remove(_pending.keys.first);
  }

  void ackReceived(int pingId, Duration now) {
    final sent = _pending.remove(pingId);
    if (sent == null) return;
    _firstAckAt ??= now;
    _rtts.add((now - sent).inMicroseconds);
    if (_rtts.length > _window) _rtts.removeAt(0);
  }

  /// Null fields (and an unknown band) keep the last known value.
  void statsReceived(StatsReport r) {
    _gotStats = true;
    _tv = StatsReport(
      tvDelayMs: r.tvDelayMs ?? _tv.tvDelayMs,
      lostPermille: r.lostPermille ?? _tv.lostPermille,
      jitterMs: r.jitterMs ?? _tv.jitterMs,
      band: r.band == WifiBand.unknown ? _tv.band : r.band,
    );
  }

  int? get _rtt =>
      _rtts.isEmpty ? null : (_rtts.reduce((a, b) => a + b) / _rtts.length / 1000).round();

  int? _delay(int? rtt) {
    final tv = _tv.tvDelayMs;
    return rtt == null || tv == null ? null : phoneMs + (rtt / 2).round() + tv;
  }

  HelloInfo get helloInfo {
    final rtt = _rtt;
    return (rttMs: rtt, delayMs: _delay(rtt));
  }

  LinkSnapshot snapshot(Duration now) {
    final rtt = _rtt;
    final delay = _delay(rtt);
    final at = _firstAckAt;
    return LinkSnapshot(
      rttMs: rtt,
      wifiMs: rtt == null ? null : (rtt / 2).round(),
      tvMs: _tv.tvDelayMs,
      delayMs: delay,
      lostPermille: _tv.lostPermille,
      jitterMs: _tv.jitterMs,
      phoneMs: phoneMs,
      tvBand: _tv.band,
      quality: qualityOf(delayMs: delay, lostPermille: _tv.lostPermille),
      tvTooOld: at != null && !_gotStats && now - at >= _tooOldAfter,
    );
  }
}
