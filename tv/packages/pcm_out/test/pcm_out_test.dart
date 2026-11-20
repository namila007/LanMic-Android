import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pcm_out/pcm_out.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];
  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('pcm_out'), (c) async {
          calls.add(c);
          return null;
        });
  });

  test('start sends the output format', () async {
    await PcmOut().start();
    expect(calls.single.method, 'start');
    expect(calls.single.arguments, {
      'sampleRate': 48000,
      'channels': 1,
      'usage': 'media',
      'contentType': 'speech',
      'lowLatency': true,
    });
  });

  test('write before start throws StateError', () {
    expect(() => PcmOut().write(Uint8List(960)), throwsStateError);
  });

  test('write of 959 bytes throws ArgumentError', () async {
    final o = PcmOut();
    await o.start();
    expect(() => o.write(Uint8List(959)), throwsArgumentError);
  });

  test('write of 960 bytes reaches the channel', () async {
    final o = PcmOut();
    await o.start();
    final f = Uint8List(960)..[0] = 7;
    await o.write(f);
    expect(calls.last.method, 'write');
    expect(calls.last.arguments, f);
  });

  test('stop invokes stop and requires a new start', () async {
    final o = PcmOut();
    await o.start();
    await o.stop();
    expect(calls.last.method, 'stop');
    expect(() => o.write(Uint8List(960)), throwsStateError);
  });
}
