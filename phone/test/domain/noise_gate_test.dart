import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanmic/domain/noise_gate.dart';

/// A 960 B frame where every sample is [v] (RMS = |v| / 32768).
Uint8List frame(int v) {
  final b = ByteData(960);
  for (var i = 0; i < 480; i++) {
    b.setInt16(i * 2, v, Endian.little);
  }
  return b.buffer.asUint8List();
}

List<int> samples(Uint8List f) {
  final b = ByteData.sublistView(f);
  return [for (var i = 0; i < 480; i++) b.getInt16(i * 2, Endian.little)];
}

const loud = 3277; // -20 dBFS
const between = 328; // -40 dBFS: under open (-38), over close (-44)
const quiet = 65; // -54 dBFS

void main() {
  late NoiseGate g;
  setUp(() => g = NoiseGate(holdFrames: 3));

  test('mutes quiet frames from the start', () {
    expect(g.process(frame(quiet)), everyElement(0));
    expect(g.isOpen, isFalse);
  });

  test('passes loud frames unchanged once open', () {
    g.process(frame(loud)); // fades in
    final f = frame(loud);
    expect(g.process(f), f);
    expect(g.isOpen, isTrue);
  });

  test('fades in over the first frame instead of jumping', () {
    final s = samples(g.process(frame(loud)));
    expect(s.first, lessThan(loud ~/ 10));
    expect(s.last, closeTo(loud, loud * 0.01));
    for (var i = 1; i < s.length; i++) {
      expect(s[i], greaterThanOrEqualTo(s[i - 1]));
    }
  });

  test('holds open through short pauses, then fades out', () {
    g.process(frame(loud));
    for (var i = 0; i < 3; i++) {
      final f = frame(quiet);
      expect(g.process(f), f, reason: 'hold frame $i');
    }
    final s = samples(g.process(frame(quiet)));
    expect(g.isOpen, isFalse);
    expect(s.first, closeTo(quiet, 1));
    expect(s.last, 0);
    expect(g.process(frame(quiet)), everyElement(0));
  });

  test('a level between the thresholds does not open a closed gate', () {
    expect(g.process(frame(between)), everyElement(0));
    expect(g.isOpen, isFalse);
  });

  test('a level between the thresholds keeps an open gate open', () {
    g.process(frame(loud));
    for (var i = 0; i < 10; i++) {
      g.process(frame(between));
    }
    expect(g.isOpen, isTrue);
  });

  test('an all-zero frame stays silent', () {
    expect(g.process(Uint8List(960)), everyElement(0));
  });

  test('takeStats reports open frames and level range, then resets', () {
    g.process(frame(quiet));
    g.process(frame(loud));
    expect(g.takeStats(), 'gate open=1/2 min=-54dB max=-20dB');
    expect(g.takeStats(), 'gate open=0/0');
  });
}
