import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanmic_protocol/lanmic_protocol.dart';
import 'package:wifi_band/wifi_band.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  void mock(Future<Object?> Function() h) => TestDefaultBinaryMessengerBinding
      .instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('wifi_band'), (_) => h());

  test('bandFromMhz maps frequencies', () {
    expect(bandFromMhz(null), WifiBand.unknown);
    expect(bandFromMhz(2412), WifiBand.ghz2_4);
    expect(bandFromMhz(5180), WifiBand.ghz5);
    expect(bandFromMhz(5955), WifiBand.ghz6);
    expect(bandFromMhz(900), WifiBand.unknown);
  });

  test('read maps the channel result', () async {
    mock(() async => 5180);
    expect(await const WifiBandReader().read(), WifiBand.ghz5);
  });

  test('read gives unknown for null', () async {
    mock(() async => null);
    expect(await const WifiBandReader().read(), WifiBand.unknown);
  });

  test('read gives unknown when the platform throws', () async {
    mock(() async => throw PlatformException(code: 'x'));
    expect(await const WifiBandReader().read(), WifiBand.unknown);
  });

  test('setLowLatency sends the flag', () async {
    Object? sent;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('wifi_band'), (c) async {
      expect(c.method, 'setLowLatency');
      sent = c.arguments;
      return null;
    });
    await const WifiBandReader().setLowLatency(true);
    expect(sent, true);
  });

  test('setLowLatency swallows PlatformException', () async {
    mock(() async => throw PlatformException(code: 'x'));
    await const WifiBandReader().setLowLatency(false);
  });
}
