import 'dart:typed_data';

import 'package:lanmic_protocol/lanmic_protocol.dart';

const _mask = 0xFFFFFFFF;

/// Modular (u32) ordering: negative when [a] comes before [b].
int _cmp(int a, int b) =>
    a == b ? 0 : (((a - b) & _mask) > 0x7FFFFFFF ? -1 : 1);

enum PopKind { voice, gap, underrun }

class JitterBuffer {
  JitterBuffer({this.prebuffer = 3, this.maxDepth = 8});

  final int prebuffer;
  final int maxDepth;
  final _frames = <int, Uint8List>{};
  final _silence = Uint8List(kFrameBytes);
  int? _lastPlayed;
  bool _playing = false;
  int underruns = 0;
  int discarded = 0; // frames thrown away by overflow trims, cumulative
  PopKind? lastPop; // null before playing and after flush

  bool get isPlaying => _playing;
  int get depth => _frames.length;

  List<int> get _sorted => _frames.keys.toList()..sort(_cmp);

  /// false = duplicate or stale.
  bool push(int seq, Uint8List frame) {
    final last = _lastPlayed;
    if (last != null && _cmp(seq, last) <= 0) return false;
    if (_frames.containsKey(seq)) return false;
    _frames[seq] = frame;
    if (_frames.length > maxDepth) {
      final keys = _sorted;
      for (final k in keys.take(keys.length - prebuffer)) {
        _frames.remove(k);
        discarded++;
      }
      _lastPlayed = (keys[keys.length - prebuffer] - 1) & _mask;
    }
    return true;
  }

  /// null until [prebuffer] frames are queued; afterwards a frame or 10 ms of silence.
  Uint8List? pop() {
    if (!_playing) {
      if (_frames.length < prebuffer) return null;
      _playing = true;
      _lastPlayed = (_sorted.first - 1) & _mask;
    }
    if (_frames.isEmpty) {
      underruns++;
      lastPop = PopKind.underrun;
      return _silence; // underrun: keep lastPlayed so late frames stay in order
    }
    var next = (_lastPlayed! + 1) & _mask;
    final first = _sorted.first;
    // A jump bigger than the buffer is a sender restart, not loss: resync instead of playing seconds of silence.
    if (((first - next) & _mask) > maxDepth) next = first;
    _lastPlayed = next;
    final f = _frames.remove(next);
    lastPop = f == null ? PopKind.gap : PopKind.voice;
    return f ?? _silence;
  }

  void flush() {
    _frames.clear();
    _lastPlayed = null;
    _playing = false;
    lastPop = null;
  }
}
