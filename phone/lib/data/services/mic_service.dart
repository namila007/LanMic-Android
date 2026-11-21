import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show PlatformException;
import 'package:lanmic/domain/send_error_monitor.dart';
import 'package:pcm_out/pcm_out.dart';

abstract class Mic {
  Future<void> open();
  Future<void> close();
  bool get isOpen;
  Object? get error;
  Stream<double> get level;

  /// Permille of samples the Mic boost limiter touched since the previous stats poll (about 100 ms).
  int get limitedPermille;
}

const _formatError = "This phone's microphone format isn't supported.";

/// Starts/stops the native capture (Oboe input + sender thread) and polls its stats at 10 Hz for the level meter.
class MicService implements Mic {
  MicService({
    required this.capture,
    this.onStats,
    this.rebind,
    this.pollEvery = const Duration(milliseconds: 100),
  });

  final NativeCapture capture;
  final void Function(CaptureStats)? onStats;
  final Future<void> Function()? rebind; // called once per run of send errors
  final Duration pollEvery;

  final _level = StreamController<double>.broadcast();
  final _errors = SendErrorMonitor();
  Timer? _timer;
  bool _polling = false;
  DateTime? _lastPollLog;
  Future<void> _chain = Future.value();
  int _epoch = 0; // bumped by close(); makes an in-flight open() a no-op
  bool _open = false;
  bool _started = false;
  @override
  Object? error;

  @override
  bool get isOpen => _open;
  @override
  Stream<double> get level => _level.stream;
  @override
  int limitedPermille = 0;

  @override
  Future<void> open() {
    final e = _epoch;
    return _run(() => _doOpen(e));
  }

  @override
  Future<void> close() {
    _epoch++;
    _open = false; // the level stops immediately, before the async teardown runs
    _timer?.cancel();
    limitedPermille = 0;
    return _run(_doClose);
  }

  // Serialised so a start can never overlap a stop on the native capture.
  Future<void> _run(Future<void> Function() f) => _chain = _chain.then((_) => f());

  Future<void> _doOpen(int e) async {
    if (e != _epoch || _open) return;
    error = null;
    try {
      await capture.start();
      _started = true;
    } on PlatformException catch (err) {
      error = err.code == 'format_unsupported' ? _formatError : err;
      return;
    } on Object catch (err) {
      error = err;
      return;
    }
    if (e != _epoch) return _doClose();
    _open = true;
    _timer = Timer.periodic(pollEvery, (_) => unawaited(_poll()));
  }

  Future<void> _doClose() async {
    _timer?.cancel();
    if (!_started) return;
    _started = false;
    try {
      await capture.stop(); // returns after the last frame was sent: END may follow
    } on Object catch (err) {
      error = err;
    }
  }

  Future<void> _poll() async {
    if (_polling) return;
    _polling = true;
    try {
      final s = await capture.stats();
      if (!_open) return;
      limitedPermille = s.limitedPermille; // before the level event: listeners read it then
      _level.add(min(1.0, s.levelRms * 4)); // same scale as the old RMS meter
      onStats?.call(s);
      if (_errors.add(s.sendErrors)) await rebind?.call();
    } on Object catch (err) {
      // a failed poll just skips one meter update; log at most every 10 s
      final now = DateTime.now();
      if (_lastPollLog == null || now.difference(_lastPollLog!) >= const Duration(seconds: 10)) {
        _lastPollLog = now;
        debugPrint('mic poll failed: $err');
      }
    } finally {
      _polling = false;
    }
  }
}
