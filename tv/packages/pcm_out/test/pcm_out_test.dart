import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pcm_out/pcm_out.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const method = MethodChannel('pcm_out');
  const events = EventChannel('pcm_out/packets');
  final calls = <MethodCall>[];

  void mock(Future<Object?> Function(MethodCall) h) =>
      messenger.setMockMethodCallHandler(method, (c) {
        calls.add(c);
        return h(c);
      });

  setUp(() {
    calls.clear();
    mock((_) async => null);
  });

  test('start and stop invoke the channel', () async {
    final r = NativeReceiver();
    await r.start();
    await r.stop();
    expect(calls.map((c) => c.method), ['start', 'stop']);
    expect(calls.first.arguments, {'port': 5004});
  });

  test('stats maps -1 to null', () async {
    mock((_) async => [1, 2, 3, 4, 5, 30, 20, 7, -1, -1, 1, 1, -1, 192, 384, 0]);
    final s = await NativeReceiver().stats();
    expect((s.received, s.played, s.lost, s.discarded, s.late), (1, 2, 3, 4, 5));
    expect((s.depthMs, s.targetMs, s.jitterMs), (30, 20, 7));
    expect(s.lastAudioAgeMs, isNull);
    expect(s.latencyMs, isNull);
    expect(s.mmap, isNull);
    expect((s.open, s.exclusive, s.burst, s.bufferFrames, s.xruns), (true, true, 192, 384, 0));
  });

  test('stats keeps real values', () async {
    mock((_) async => [0, 0, 0, 0, 0, 0, 0, 0, 12, 25, 1, 0, 1, 96, 192, 3]);
    final s = await NativeReceiver().stats();
    expect(s.lastAudioAgeMs, 12);
    expect(s.latencyMs, 25);
    expect(s.mmap, true);
    expect(s.exclusive, false);
    expect(s.xruns, 3);
  });

  test('accept passes host/port/pin and null clears', () async {
    final r = NativeReceiver();
    await r.accept('192.168.1.5', 40000, 482917);
    expect(calls.last.method, 'accept');
    expect(calls.last.arguments, {'host': '192.168.1.5', 'port': 40000, 'pin': 482917});
    await r.accept(null, null, null);
    expect(calls.last.arguments, {'host': null, 'port': null, 'pin': null});
  });

  test('send forwards bytes and surfaces PlatformException', () async {
    final r = NativeReceiver();
    final d = Uint8List.fromList([1, 2, 3]);
    await r.send(d, '192.168.1.5', 40000);
    expect(calls.last.method, 'send');
    expect(calls.last.arguments, {'data': d, 'host': '192.168.1.5', 'port': 40000});
    mock((_) async => throw PlatformException(code: 'send_failed'));
    expect(r.send(d, '192.168.1.5', 40000), throwsA(isA<PlatformException>()));
  });

  test('packets decodes {data,host,port} and bound/error go to socketEvents', () async {
    late MockStreamHandlerEventSink sink;
    messenger.setMockStreamHandler(
      events,
      MockStreamHandler.inline(onListen: (_, s) => sink = s),
    );
    final r = NativeReceiver();
    final packets = <({Uint8List data, String host, int port})>[];
    final sockEvents = <String>[];
    final a = r.packets.listen(packets.add);
    final b = r.socketEvents.listen(sockEvents.add);
    await Future<void>.delayed(Duration.zero);
    sink.success({'data': Uint8List.fromList([9, 8]), 'host': '10.0.0.2', 'port': 41000});
    sink.success({'event': 'bound', 'message': 'port 5004'});
    sink.success({'event': 'error', 'message': 'bind failed'});
    await Future<void>.delayed(Duration.zero);
    expect(packets.single.data, [9, 8]);
    expect((packets.single.host, packets.single.port), ('10.0.0.2', 41000));
    expect(sockEvents, ['bound: port 5004', 'error: bind failed']);
    await a.cancel();
    await b.cancel();
  });
}
