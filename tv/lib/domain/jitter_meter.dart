/// RFC 3550 interarrival jitter for 10 ms audio packets.
class JitterMeter {
  int? _prevSeq;
  DateTime? _prevAt;
  double? _j;

  int? get jitterMs => _j?.round();

  void onAudio(int seq, DateTime at) {
    final ps = _prevSeq, pa = _prevAt;
    _prevSeq = seq;
    _prevAt = at;
    if (ps == null || pa == null) return;
    final dSeq = (seq - ps).toSigned(32);
    final d = (at.difference(pa).inMilliseconds - dSeq * 10).abs();
    final j = _j ?? 0;
    _j = j + (d - j) / 16;
  }

  /// Forget the previous arrival (a flush makes the next gap meaningless); keep the estimate.
  void restart() {
    _prevSeq = null;
    _prevAt = null;
  }

  void clear() {
    restart();
    _j = null;
  }
}
