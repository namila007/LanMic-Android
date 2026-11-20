import "dart:async";
import "dart:typed_data";

import 'package:flutter_test/flutter_test.dart';
import 'package:lanmic/data/services/mic_service.dart';

import '../support/fakes.dart';

Uint8List bytes(int n) => Uint8List(n);

Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  late FakePcmSource src;
  late List<Uint8List> frames;
  late MicService mic;
  setUp(() {
    src = FakePcmSource();
    frames = [];
    mic = MicService(source: src, onFrame: frames.add);
  });

  test('chunks 7,953,961 -> two 960 B frames', () async {
    await mic.open();
    for (final n in [7, 953, 961]) {
      src.controller.add(bytes(n));
    }
    await settle();
    expect(frames.map((f) => f.length), [960, 960]);
  });

  test('bytes after close() are dropped', () async {
    await mic.open();
    await mic.close();
    src.controller.add(bytes(960));
    await settle();
    expect(frames, isEmpty);
    expect(mic.isOpen, false);
  });

  test(
    'close() resets slicer: leftover not prepended to next open()',
    () async {
      await mic.open();
      src.controller.add(bytes(500));
      await settle();
      await mic.close();
      await mic.open();
      src.controller.add(bytes(500));
      await settle();
      expect(frames, isEmpty);
    },
  );

  test('open twice is a no-op', () async {
    await mic.open();
    await mic.open();
    expect(src.starts, 1);
    expect(mic.isOpen, true);
  });

  test('level: silence 0.0, full-scale square >= 0.95', () async {
    final levels = <double>[];
    mic.level.listen(levels.add);
    await mic.open();
    src.controller.add(bytes(960));
    final loud = ByteData(960);
    for (var i = 0; i < 480; i++) {
      loud.setInt16(i * 2, i.isEven ? 32767 : -32768, Endian.little);
    }
    src.controller.add(loud.buffer.asUint8List());
    await settle();
    expect(levels, [0.0, greaterThanOrEqualTo(0.95)]);
  });

  test(
    'source.start throws -> open completes, isOpen false, error set',
    () async {
      src.startError = StateError('no mic');
      await mic.open();
      expect(mic.isOpen, false);
      expect(mic.error, isA<StateError>());
    },
  );

  test('close() while start is pending leaves the mic closed', () async {
    src.startGate = Completer<void>();
    final opening = mic.open();
    final closing = mic.close();
    src.startGate!.complete();
    await opening;
    await closing;
    expect(mic.isOpen, false);
  });
}
