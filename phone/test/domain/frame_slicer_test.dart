import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanmic/domain/frame_slicer.dart';

Uint8List bytes(int n, [int start = 0]) =>
    Uint8List.fromList([for (var i = 0; i < n; i++) (start + i) % 256]);

void main() {
  test('960 B in -> one 960 B frame', () {
    final s = FrameSlicer();
    final out = s.add(bytes(960)).toList();
    expect(out.map((f) => f.length), [960]);
    expect(s.pending, 0);
  });

  test('1 B chunks x 960 -> exactly one frame, pending 0', () {
    final s = FrameSlicer();
    final out = [for (var i = 0; i < 960; i++) ...s.add(bytes(1))];
    expect(out.length, 1);
    expect(s.pending, 0);
  });

  test('odd chunks 7,953,961,3 -> frames [960,960] pending 4', () {
    final s = FrameSlicer();
    final out = [
      for (final n in [7, 953, 961, 3]) ...s.add(bytes(n)),
    ];
    expect(out.map((f) => f.length), [960, 960]);
    expect(s.pending, 4);
  });

  test('frame bytes equal the input stream in order', () {
    final s = FrameSlicer();
    final input = bytes(5000);
    final out = <int>[];
    for (var i = 0; i < input.length; i += 333) {
      final end = i + 333 > input.length ? input.length : i + 333;
      for (final f in s.add(input.sublist(i, end))) {
        out.addAll(f);
      }
    }
    expect(out, input.sublist(0, out.length));
    expect(out.length, 4800);
  });

  test('frames are copies', () {
    final s = FrameSlicer();
    final chunk = bytes(960);
    final frame = s.add(chunk).single;
    chunk[0] = 99;
    expect(frame[0], 0);
  });

  test('reset drops pending', () {
    final s = FrameSlicer()..add(bytes(500));
    s.reset();
    expect(s.pending, 0);
  });

  test('empty chunk -> no frames', () {
    expect(FrameSlicer().add(Uint8List(0)), isEmpty);
  });
}
