const _buckets = 10; // 1 s each

/// Lost audio over the last 10 s, from fixed 1 s buckets (no allocation per frame).
class LossMeter {
  final _id = List<int>.filled(_buckets, -1);
  final _lost = List<int>.filled(_buckets, 0);
  final _slots = List<int>.filled(_buckets, 0);

  int _slot(DateTime now) {
    final b = now.millisecondsSinceEpoch ~/ 1000;
    final i = b % _buckets;
    if (_id[i] != b) {
      _id[i] = b;
      _lost[i] = 0;
      _slots[i] = 0;
    }
    return i;
  }

  void played(DateTime now, {required bool lost}) {
    final i = _slot(now);
    _slots[i]++;
    if (lost) _lost[i]++;
  }

  void discarded(DateTime now, int n) {
    if (n <= 0) return;
    final i = _slot(now);
    _slots[i] += n;
    _lost[i] += n;
  }

  int? lostPermille(DateTime now) {
    final nowB = now.millisecondsSinceEpoch ~/ 1000;
    var lost = 0, slots = 0;
    for (var i = 0; i < _buckets; i++) {
      if (_id[i] > nowB - _buckets) {
        lost += _lost[i];
        slots += _slots[i];
      }
    }
    return slots == 0 ? null : (lost * 1000 / slots).round();
  }

  void clear() {
    _id.fillRange(0, _buckets, -1);
  }
}
