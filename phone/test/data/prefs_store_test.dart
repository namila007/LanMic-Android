import 'package:flutter_test/flutter_test.dart';
import 'package:lanmic/data/services/prefs_store.dart';
import 'package:lanmic/domain/phone_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('defaults: no ip, hold', () async {
    final r = await PrefsStore().load();
    expect(r.ip, isNull);
    expect(r.mode, TalkMode.hold);
  });

  test('save then load round-trips ip and mode', () async {
    final p = PrefsStore();
    await p.save(ip: '10.0.0.5', mode: TalkMode.keep);
    final r = await p.load();
    expect(r.ip, '10.0.0.5');
    expect(r.mode, TalkMode.keep);
  });

  test('saving only mode keeps ip', () async {
    final p = PrefsStore();
    await p.save(ip: '10.0.0.5');
    await p.save(mode: TalkMode.keep);
    expect((await p.load()).ip, '10.0.0.5');
  });
}
