final _ipv4 = RegExp(
  r'^(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}$',
);
final _pin = RegExp(r'^\d{6}$');

// Leading zeros in an octet ('01.2.3.4') are rejected: ambiguous octal.
bool isValidIpv4(String s) => _ipv4.hasMatch(s);

int? parsePin(String s) => _pin.hasMatch(s) ? int.parse(s) : null;
