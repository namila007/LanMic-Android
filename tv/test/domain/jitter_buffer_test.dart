import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanmic_protocol/lanmic_protocol.dart';
import 'package:lanmic_tv/domain/jitter_buffer.dart';

Uint8List frame(int tag) => Uint8List(kFrameBytes)..[0] = tag;
bool isSilence(Uint8List? f) =>
    f != null && f.length == kFrameBytes && f.every((b) => b == 0);

void main() {
  underrunCounter();
  late JitterBuffer b;
  setUp(() => b = JitterBuffer());

  // Frames carry their seq (low byte) in byte 0 so pops can be identified.
  void pushAll(List<int> seqs) {
    for (final s in seqs) {
      b.push(s, frame(s & 0xFF));
    }
  }

  List<int?> popTags(int n) => [for (var i = 0; i < n; i++) b.pop()?[0]];

  test('pop returns null until 3 frames', () {
    pushAll([1, 2]);
    expect(b.pop(), isNull);
    pushAll([3]);
    expect(popTags(3), [1, 2, 3]);
  });

  test('reorders', () {
    pushAll([2, 1, 3]);
    expect(popTags(3), [1, 2, 3]);
  });

  test('duplicate ignored', () {
    expect(b.push(5, frame(5)), isTrue);
    expect(b.push(5, frame(5)), isFalse);
    expect(b.depth, 1);
  });

  test('stale dropped', () {
    pushAll([3, 4, 5]);
    popTags(3);
    expect(b.push(5, frame(5)), isFalse);
    expect(b.push(4, frame(4)), isFalse);
  });

  test('gap gives silence', () {
    pushAll([10, 12, 13]);
    expect(b.pop()![0], 10);
    expect(isSilence(b.pop()), isTrue);
    expect(popTags(2), [12, 13]);
  });

  test('underrun gives silence', () {
    pushAll([1, 2, 3]);
    popTags(3);
    expect(isSilence(b.pop()), isTrue);
    expect(b.isPlaying, isTrue);
  });

  test('frame after an underrun is still in order, not stale', () {
    pushAll([1, 2, 3]);
    popTags(3);
    for (var i = 0; i < 5; i++) {
      b.pop();
    }
    expect(b.push(4, frame(4)), isTrue);
    expect(b.pop()![0], 4);
  });

  test('depth 8 keeps all; 9th trims to 3 newest', () {
    pushAll([1, 2, 3, 4, 5, 6, 7, 8]);
    expect(b.depth, 8);
    b.push(9, frame(9));
    expect(b.depth, 3);
    expect(popTags(3), [7, 8, 9]);
  });

  test('u32 wrap', () {
    b.push(0xFFFFFFFE, frame(0xFE));
    b.push(0xFFFFFFFF, frame(0xFF));
    b.push(0, frame(0));
    popTags(3);
    expect(b.push(0xFFFFFFFD, frame(0)), isFalse);
    pushAll([1, 2, 3]);
    expect(popTags(3), [1, 2, 3]);
  });

  test('u32 wrap in the very first batch', () {
    b.push(0, frame(0));
    b.push(0xFFFFFFFF, frame(0xFF));
    b.push(1, frame(1));
    expect(popTags(3), [0xFF, 0, 1]);
  });

  test('large forward jump resyncs instead of playing silence', () {
    pushAll([1, 2, 3]);
    popTags(3);
    pushAll([5000, 5001, 5002]);
    expect(b.pop()![0], 5000 & 0xFF);
  });

  test('flush resets', () {
    pushAll([498, 499, 500]);
    popTags(3);
    b.flush();
    expect(b.depth, 0);
    expect(b.isPlaying, isFalse);
    expect(b.push(1, frame(1)), isTrue);
  });
}

void underrunCounter() {
  test('underruns counts silence from an empty buffer, not from gaps', () {
    final b = JitterBuffer();
    for (final s in [1, 2, 4]) {
      b.push(s, frame(s));
    }
    for (var i = 0; i < 4; i++) {
      b.pop(); // 1, 2, gap(3), 4
    }
    expect(b.underruns, 0);
    b.pop();
    b.pop();
    expect(b.underruns, 2);
  });
}
