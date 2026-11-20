import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

abstract class PinStore {
  Future<int> load();
}

class SharedPrefsPinStore implements PinStore {
  SharedPrefsPinStore(this._prefs, [Random? random])
    : _random = random ?? Random.secure();

  final SharedPreferences _prefs;
  final Random _random;

  @override
  Future<int> load() async {
    final saved = _prefs.getInt('pin');
    if (saved != null) return saved;
    final pin = 100000 + _random.nextInt(900000);
    await _prefs.setInt('pin', pin);
    return pin;
  }
}
