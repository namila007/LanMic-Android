import 'package:flutter_test/flutter_test.dart';
import 'package:lanmic/data/services/permission_service.dart';
import 'package:lanmic/data/services/prefs_store.dart';
import 'package:lanmic/domain/phone_state.dart';
import 'package:lanmic/ui/features/mic/view_models/mic_view_model.dart';
import 'package:lanmic/ui/features/mic/view_models/stats_text.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../support/fakes.dart';

void main() {
  late List<String> log;
  late FakeSession session;
  late FakeMic mic;
  late List<int> gains;

  MicViewModel build() => MicViewModel(
    session: session,
    mic: mic,
    prefs: PrefsStore(),
    perms: FakePerms(log)..mic.add(PermStatus.granted),
    fgs: FakeFgs(log),
    focus: FakeFocus(log),
    keepAwake: (_) {},
    now: () => DateTime.utc(2026),
    setMicGain: (db) async => gains.add(db),
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    log = [];
    session = FakeSession(log);
    mic = FakeMic(log);
    gains = [];
  });

  test('mic boost defaults to 0 dB and is applied on init', () async {
    final vm = build();
    await vm.init();
    expect(vm.micBoostDb, 0);
    expect(gains, [0]);
  });

  test('mic boost clamps to ±12, saves and applies natively', () async {
    final vm = build();
    await vm.init();
    await vm.setMicBoost(3);
    await vm.setMicBoost(40);
    await vm.setMicBoost(-40);
    expect(gains, [0, 3, 12, -12]);
    expect(vm.micBoostDb, -12);
    expect((await PrefsStore().load()).micBoostDb, -12);
  });

  test('mic boost is restored from prefs on init and applied', () async {
    SharedPreferences.setMockInitialValues({'micBoostDb': 5});
    final vm = build();
    await vm.init();
    expect(vm.micBoostDb, 5);
    expect(gains, [5]);
  });

  test('limiting hint only while live and above 2% limited', () async {
    final vm = build();
    await vm.init();
    mic.limitedPermille = 30;
    expect(vm.micLimiting, isFalse); // not live
    await vm.connect('192.168.1.42', '482917');
    session.emit(PhoneState.connected);
    await vm.tapTalkToLive();
    expect(vm.micLimiting, isTrue);
    mic.limitedPermille = 20;
    expect(vm.micLimiting, isFalse); // 2% is not above 2%
  });

  test('dB text and spoken copy', () {
    expect(dbText(0), '0 dB');
    expect(dbText(3), '+3 dB');
    expect(dbText(-6), '−6 dB'); // real minus sign
    expect(dbSpoken(3), 'plus 3 decibels');
    expect(dbSpoken(-6), 'minus 6 decibels');
    expect(dbSpoken(0), '0 decibels');
  });
}

extension on MicViewModel {
  /// Keep mode + tap: the quickest way to `PhoneState.live` in these fakes.
  Future<void> tapTalkToLive() async {
    await setMode(TalkMode.keep);
    tapTalk();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }
}
