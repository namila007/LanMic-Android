import 'dart:io';

class NetworkInfoService {
  /// First non-loopback IPv4 address, or null when offline.
  Future<String?> localIpv4() async {
    final ifaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
    for (final i in ifaces) {
      for (final a in i.addresses) {
        return a.address;
      }
    }
    return null;
  }
}
