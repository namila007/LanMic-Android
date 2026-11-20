import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanmic_protocol/lanmic_protocol.dart';
import 'package:lanmic_tv/domain/jitter_buffer.dart';

Uint8List frame(int tag) => Uint8List(kFrameBytes)..[0] = tag;

void main() {
  test('lastPop tells voice, gap and underrun apart', () {
    final b = JitterBuffer(prebuffer: 2, maxDepth: 8);
    expect(b.lastPop, isNull);
    b.push(0, frame(1));
    b.push(2, frame(3));
    b.pop();
    expect(b.lastPop, PopKind.voice);
    b.pop(); // seq 1 never arrived
    expect(b.lastPop, PopKind.gap);
    b.pop();
    expect(b.lastPop, PopKind.voice);
    b.pop(); // buffer empty
    expect(b.lastPop, PopKind.underrun);
  });

  test('a pop before prebuffer is reached leaves lastPop null', () {
    final b = JitterBuffer(prebuffer: 3)..push(0, frame(1));
    expect(b.pop(), isNull);
    expect(b.lastPop, isNull);
  });

  test('flush clears lastPop but keeps the discarded count', () {
    final b = JitterBuffer(prebuffer: 1)..push(0, frame(1));
    for (var i = 1; i < 10; i++) {
      b.push(i, frame(i));
    }
    b.pop();
    final discarded = b.discarded;
    b.flush();
    expect(b.lastPop, isNull);
    expect(b.discarded, discarded);
  });

  test('overflow trim counts the frames it throws away', () {
    final b = JitterBuffer(prebuffer: 3, maxDepth: 8);
    for (var i = 0; i < 9; i++) {
      b.push(i, frame(i));
    }
    expect(b.discarded, 6); // 9 > 8: trimmed down to prebuffer
    expect(b.depth, 3);
  });

  test('duplicates and stale frames are not discards', () {
    final b = JitterBuffer(prebuffer: 1)..push(5, frame(5));
    b.push(5, frame(5));
    b.pop();
    b.push(4, frame(4));
    expect(b.discarded, 0);
  });
}
