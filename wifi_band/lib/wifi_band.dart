import 'package:flutter/services.dart';
import 'package:lanmic_protocol/lanmic_protocol.dart';

WifiBand bandFromMhz(int? mhz) {
  if (mhz == null) return WifiBand.unknown;
  if (mhz >= 2400 && mhz <= 2500) return WifiBand.ghz2_4;
  if (mhz >= 4900 && mhz <= 5899) return WifiBand.ghz5;
  if (mhz >= 5925 && mhz <= 7125) return WifiBand.ghz6;
  return WifiBand.unknown;
}

/// Reads the band of the connected Wi-Fi network. Never throws.
class WifiBandReader {
  const WifiBandReader();
  static const _channel = MethodChannel('wifi_band');

  Future<WifiBand> read() async {
    try {
      return bandFromMhz(await _channel.invokeMethod<int>('frequencyMhz'));
    } on PlatformException {
      return WifiBand.unknown;
    } on MissingPluginException {
      return WifiBand.unknown;
    }
  }
}
