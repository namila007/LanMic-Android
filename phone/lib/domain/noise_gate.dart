import 'dart:math';
import 'dart:typed_data';

/// Mutes 10 ms PCM16 frames while the mic only hears background (e.g. the TV
/// itself), breaking the TV -> mic -> TV echo loop between phrases.
///
/// Muted frames become silence, not drops, so the TV still gets 100 frames/s.
/// Opens at [openDb], closes after [holdFrames] frames below [closeDb]; each
/// change fades over one frame so it never clicks.
class NoiseGate {
  // shortcut: fixed thresholds tuned on a Pixel 7 held close; make them a
  // user setting if other phones or singing distances need different values.
  NoiseGate({this.openDb = -38, this.closeDb = -44, this.holdFrames = 25});

  final double openDb, closeDb;
  final int holdFrames;

  bool _open = false;
  double _gain = 0;
  int _quiet = 0;
  int _frames = 0, _openFrames = 0;
  double _minDb = double.infinity, _maxDb = double.negativeInfinity;

  bool get isOpen => _open;

  Uint8List process(Uint8List frame) {
    final db = _dbfs(frame);
    if (db >= (_open ? closeDb : openDb)) {
      _open = true;
      _quiet = 0;
    } else if (_open && ++_quiet > holdFrames) {
      _open = false;
    }
    _frames++;
    if (_open) _openFrames++;
    _minDb = min(_minDb, db);
    _maxDb = max(_maxDb, db);

    final from = _gain, to = _open ? 1.0 : 0.0;
    _gain = to;
    if (from == to) return to == 1 ? frame : Uint8List(frame.length);
    final src = ByteData.sublistView(frame);
    final out = ByteData(frame.length);
    final n = frame.length ~/ 2;
    for (var i = 0; i < n; i++) {
      final g = from + (to - from) * (i + 1) / n;
      out.setInt16(
        i * 2,
        (src.getInt16(i * 2, Endian.little) * g).round(),
        Endian.little,
      );
    }
    return out.buffer.asUint8List();
  }

  /// One log line for calibrating the thresholds on a real phone; resets the counts.
  String takeStats() {
    final s = _frames == 0
        ? 'gate open=0/0'
        : 'gate open=$_openFrames/$_frames '
              'min=${_minDb.round()}dB max=${_maxDb.round()}dB';
    _frames = _openFrames = 0;
    _minDb = double.infinity;
    _maxDb = double.negativeInfinity;
    return s;
  }

  static double _dbfs(Uint8List f) {
    final b = ByteData.sublistView(f);
    final n = f.length ~/ 2;
    var sum = 0.0;
    for (var i = 0; i < n; i++) {
      final s = b.getInt16(i * 2, Endian.little);
      sum += s * s;
    }
    final rms = n == 0 ? 0 : sqrt(sum / n) / 32768;
    return rms == 0 ? -120 : 20 * log(rms) / ln10;
  }
}
