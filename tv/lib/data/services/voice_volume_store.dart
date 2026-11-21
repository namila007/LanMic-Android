import 'package:shared_preferences/shared_preferences.dart';

/// The TV's Voice volume in dB (-12..+12), kept across restarts and reboots.
abstract class VoiceVolumeStore {
  Future<int> load();
  Future<void> save(int db);
}

class SharedPrefsVoiceVolumeStore implements VoiceVolumeStore {
  SharedPrefsVoiceVolumeStore(this._prefs);

  final SharedPreferences _prefs;

  @override
  Future<int> load() async => (_prefs.getInt('voiceVolumeDb') ?? 0).clamp(-12, 12);

  @override
  Future<void> save(int db) => _prefs.setInt('voiceVolumeDb', db);
}
