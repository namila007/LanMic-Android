import 'package:flutter_test/flutter_test.dart';
import 'package:lanmic/domain/input_validation.dart';

void main() {
  test(
    'accepts a dotted quad',
    () => expect(isValidIpv4('192.168.1.42'), true),
  );

  for (final bad in [
    '',
    'tv.local',
    '1.2.3',
    '1.2.3.4.5',
    '256.1.1.1',
    '1.2.3.-1',
    ' 1.2.3.4',
    '01.2.3.4x',
  ]) {
    test('rejects "$bad"', () => expect(isValidIpv4(bad), false));
  }

  test('pin accepts 000000 as 0', () => expect(parsePin('000000'), 0));
  test('pin accepts 482917', () => expect(parsePin('482917'), 482917));
  for (final bad in ['12345', '1234567', '12345a', '']) {
    test('pin rejects "$bad"', () => expect(parsePin(bad), isNull));
  }
}
