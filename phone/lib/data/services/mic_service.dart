import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:lanmic/domain/frame_slicer.dart';
import 'package:record/record.dart';

abstract class PcmSource {
  Future<void> start();
  Future<void> stop();
  Stream<Uint8List> get pcm;
}

/// 48 kHz mono PCM16 from the phone mic, processing off (raw voice, low latency).
class RecordPcmSource implements PcmSource {
  final _rec = AudioRecorder();
  Stream<Uint8List>? _stream;

  @override
  Future<void> start() async {
    _stream = await _rec.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 48000,
        numChannels: 1,
        androidConfig: AndroidRecordConfig(audioSource: AndroidAudioSource.mic),
        echoCancel: false,
        noiseSuppress: false,
        autoGain: false,
        // record must not request audio focus itself: it would steal the
        // app's own focus (AudioFocus) and look like a phone call.
        audioInterruption: AudioInterruptionMode.none,
      ),
    );
  }

  @override
  Future<void> stop() async {
    await _rec.stop();
  }

  @override
  Stream<Uint8List> get pcm => _stream ?? const Stream.empty();
}

/// Opens/closes the capture and emits exact 960 B frames only while open.
class MicService {
  MicService({required this.source, required this.onFrame});

  final PcmSource source;
  final void Function(Uint8List frame) onFrame;

  final _slicer = FrameSlicer();
  final _level = StreamController<double>.broadcast();
  StreamSubscription<Uint8List>? _sub;
  Future<void> _chain = Future.value();
  int _epoch = 0; // bumped by close(); makes an in-flight open() a no-op
  bool _open = false;
  bool _started = false;
  Object? error;

  bool get isOpen => _open;
  Stream<double> get level => _level.stream;

  Future<void> open() {
    final e = _epoch;
    return _run(() => _doOpen(e));
  }

  Future<void> close() {
    _epoch++;
    _open = false; // frames stop immediately, before the async teardown runs
    return _run(_doClose);
  }

  // Serialised so a start can never overlap a stop on the recorder.
  Future<void> _run(Future<void> Function() f) =>
      _chain = _chain.then((_) => f());

  Future<void> _doOpen(int e) async {
    if (e != _epoch || _open) return;
    error = null;
    try {
      await source.start();
      _started = true;
    } on Object catch (err) {
      error = err;
      return;
    }
    if (e != _epoch) return _doClose();
    _slicer.reset();
    _open = true;
    _sub = source.pcm.listen(_onChunk);
  }

  Future<void> _doClose() async {
    await _sub?.cancel();
    _sub = null;
    _slicer.reset();
    if (!_started) return;
    _started = false;
    try {
      await source.stop();
    } on Object catch (err) {
      error = err;
    }
  }

  void _onChunk(Uint8List chunk) {
    if (!_open) return;
    _level.add(_rms(chunk));
    for (final f in _slicer.add(chunk)) {
      onFrame(f);
    }
  }

  static double _rms(Uint8List b) {
    final bd = ByteData.sublistView(b);
    final n = b.length ~/ 2;
    if (n == 0) return 0;
    var sum = 0.0;
    for (var i = 0; i < n; i++) {
      final s = bd.getInt16(i * 2, Endian.little);
      sum += s * s;
    }
    return min(1.0, sqrt(sum / n) / 32768);
  }
}
