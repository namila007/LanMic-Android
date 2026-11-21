import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanmic/data/services/mic_service.dart';
import 'package:pcm_out/pcm_out.dart';

CaptureStats cs({double level = 0, int sendErrors = 0, int limited = 0}) => CaptureStats.fromList(
  [1, 12, 0, 0, 0, sendErrors, 10, (level * 1000).round(), 0, 0, 0, 0, 1, 1, 96, 0, limited],
);

class _FakeCapture extends NativeCapture {
  final calls = <String>[];
  Object? startError;
  CaptureStats next = cs();
  bool failStats = false;
  int statsCalls = 0;

  @override
  Future<void> start() async {
    calls.add('start');
    if (startError != null) throw startError!;
  }

  @override
  Future<void> stop() async => calls.add('stop');

  @override
  Future<CaptureStats> stats() async {
    statsCalls++;
    if (failStats) throw PlatformException(code: 'boom');
    return next;
  }
}

void main() {
  test('open starts capture once; close stops it', () async {
    final c = _FakeCapture();
    final m = MicService(capture: c);
    await m.open();
    await m.open();
    expect(m.isOpen, true);
    await m.close();
    expect(m.isOpen, false);
    expect(c.calls, ['start', 'stop']);
  });

  test('mic service maps format_unsupported to the error copy', () async {
    final c = _FakeCapture()..startError = PlatformException(code: 'format_unsupported');
    final m = MicService(capture: c);
    await m.open();
    expect(m.isOpen, false);
    expect(m.error, "This phone's microphone format isn't supported.");
    c.startError = PlatformException(code: 'open_failed');
    await m.open();
    expect(m.error, isA<PlatformException>());
  });

  test('close before a queued open runs cancels it', () {
    fakeAsync((a) {
      final c = _FakeCapture();
      final m = MicService(capture: c);
      unawaited(m.open());
      unawaited(m.close());
      a.flushMicrotasks();
      expect(m.isOpen, false);
      expect(c.calls, isEmpty);
    });
  });

  test('level stream from stats', () {
    fakeAsync((a) {
      final c = _FakeCapture()..next = cs(level: 0.1);
      final m = MicService(capture: c);
      final got = <double>[];
      m.level.listen(got.add);
      unawaited(m.open());
      a.elapse(const Duration(milliseconds: 250));
      expect(got, isNotEmpty);
      expect(got.first, closeTo(0.4, 1e-9)); // levelRms * 4, as the old RMS meter
      c.next = cs(level: 0.5); // clamps at 1
      a.elapse(const Duration(milliseconds: 100));
      expect(got.last, 1.0);
      unawaited(m.close());
      a.flushMicrotasks();
    });
  });

  test('limitedPermille follows the stats poll and clears on close', () {
    fakeAsync((a) {
      final c = _FakeCapture()..next = cs(limited: 40);
      final m = MicService(capture: c);
      unawaited(m.open());
      a.elapse(const Duration(milliseconds: 250));
      expect(m.limitedPermille, 40);
      unawaited(m.close());
      a.flushMicrotasks();
      expect(m.limitedPermille, 0);
    });
  });

  test('send errors rising for 1 s call rebind once', () {
    fakeAsync((a) {
      final c = _FakeCapture();
      var rebinds = 0;
      final m = MicService(capture: c, rebind: () async => rebinds++);
      unawaited(m.open());
      var n = 0;
      // errors rise on every poll for 3 s: one rebind, not one per poll
      for (var i = 0; i < 30; i++) {
        c.next = cs(sendErrors: ++n);
        a.elapse(const Duration(milliseconds: 100));
      }
      expect(rebinds, 1);
      c.next = cs(sendErrors: n); // errors stop: re-armed
      a.elapse(const Duration(milliseconds: 300));
      for (var i = 0; i < 12; i++) {
        c.next = cs(sendErrors: ++n);
        a.elapse(const Duration(milliseconds: 100));
      }
      expect(rebinds, 2);
      unawaited(m.close());
      a.flushMicrotasks();
    });
  });

  test('short error bursts do not rebind', () {
    fakeAsync((a) {
      final c = _FakeCapture();
      var rebinds = 0;
      final m = MicService(capture: c, rebind: () async => rebinds++);
      unawaited(m.open());
      var n = 0;
      for (var i = 0; i < 40; i++) {
        if (i % 5 != 0) n++; // a quiet poll every 5th
        c.next = cs(sendErrors: n);
        a.elapse(const Duration(milliseconds: 100));
      }
      expect(rebinds, 0);
      unawaited(m.close());
      a.flushMicrotasks();
    });
  });

  test("rebind() throwing inside _poll doesn't stop polling", () {
    fakeAsync((a) {
      final c = _FakeCapture();
      final m = MicService(capture: c, rebind: () async => throw StateError('rebind'));
      unawaited(m.open());
      var n = 0;
      for (var i = 0; i < 15; i++) {
        c.next = cs(sendErrors: ++n);
        a.elapse(const Duration(milliseconds: 100));
      }
      final before = c.statsCalls;
      a.elapse(const Duration(milliseconds: 500));
      expect(c.statsCalls, greaterThan(before));
      unawaited(m.close());
      a.flushMicrotasks();
    });
  });

  test('stats() throwing then recovering keeps level updating', () {
    fakeAsync((a) {
      final c = _FakeCapture()..failStats = true;
      final m = MicService(capture: c);
      final got = <double>[];
      m.level.listen(got.add);
      unawaited(m.open());
      a.elapse(const Duration(milliseconds: 500));
      expect(got, isEmpty);
      c
        ..failStats = false
        ..next = cs(level: 0.1);
      a.elapse(const Duration(milliseconds: 300));
      expect(got, isNotEmpty);
      unawaited(m.close());
      a.flushMicrotasks();
    });
  });
}
