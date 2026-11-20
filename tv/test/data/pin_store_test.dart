import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanmic_tv/data/services/pin_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Rand implements Random {
  int calls = 0;
  @override
  int nextInt(int max) {
    calls++;
    return 82917;
  }

  @override
  bool nextBool() => false;
  @override
  double nextDouble() => 0;
}

void main() {
  test('generates a 6-digit PIN once and persists it', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final r1 = _Rand();
    final pin = await SharedPrefsPinStore(prefs, r1).load();
    expect(pin, inInclusiveRange(100000, 999999));
    expect(pin, 182917);
    final r2 = _Rand();
    expect(await SharedPrefsPinStore(prefs, r2).load(), pin);
    expect(r2.calls, 0);
  });
}
