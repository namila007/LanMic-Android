import 'package:flutter_test/flutter_test.dart';
import 'package:lanmic_tv/domain/playback_pump.dart';

void main() {
  var ms = 0;
  var frames = 0;
  late PlaybackPump pump;
  setUp(() {
    ms = 0;
    frames = 0;
    pump = PlaybackPump(
      elapsed: () => Duration(milliseconds: ms),
      onFrame: () => frames++,
    );
  });

  int tickAt(int t) {
    ms = t;
    final before = frames;
    pump.tick();
    return frames - before;
  }

  test('one frame per 10 ms', () {
    expect(tickAt(10), 1);
    expect(tickAt(20), 1);
  });

  test('a tick 15 ms late still emits one frame (floor)', () {
    tickAt(10);
    tickAt(20);
    expect(tickAt(35), 1);
  });

  test('a long stall emits at most 3 frames, then resyncs without backlog', () {
    tickAt(10);
    tickAt(20);
    tickAt(30);
    expect(tickAt(200), 3);
    expect(tickAt(210), 1);
  });

  test('a backward clock step resyncs instead of going silent', () {
    tickAt(10);
    tickAt(20);
    tickAt(30);
    expect(tickAt(5), 0); // e.g. NTP stepped the wall clock back after boot
    expect(tickAt(15), 1);
  });

  test('a tick before the next boundary emits nothing', () {
    expect(tickAt(9), 0);
  });
}
