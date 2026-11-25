import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final manifest = File('android/app/src/main/AndroidManifest.xml')
      .readAsStringSync();
  final gradle = File('android/app/build.gradle.kts').readAsStringSync();

  for (final p in [
    'RECORD_AUDIO',
    'INTERNET',
    'ACCESS_WIFI_STATE',
    'CHANGE_WIFI_STATE',
    'FOREGROUND_SERVICE',
    'FOREGROUND_SERVICE_MICROPHONE',
    'POST_NOTIFICATIONS',
    'WAKE_LOCK',
  ]) {
    test('main manifest declares $p', () {
      expect(manifest, contains('android.permission.$p"'));
    });
  }

  test('foreground service has microphone type and is not exported', () {
    final s = RegExp(
      r'<service[^>]*com\.pravera\.flutter_foreground_task\.service\.ForegroundService[^>]*>',
      dotAll: true,
    ).firstMatch(manifest)?.group(0);
    expect(s, isNotNull);
    expect(s, contains('android:foregroundServiceType="microphone"'));
    expect(s, contains('android:exported="false"'));
  });

  test('gradle pins minSdk 26 and targetSdk 36 (Play requirement)', () {
    expect(gradle, matches(RegExp(r'minSdk\s*=\s*26\b')));
    expect(gradle, matches(RegExp(r'targetSdk\s*=\s*36\b')));
    expect(gradle, isNot(contains('flutter.minSdkVersion')));
    expect(gradle, isNot(contains('flutter.targetSdkVersion')));
  });
}
