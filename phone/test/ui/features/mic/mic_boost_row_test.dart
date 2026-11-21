import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanmic/data/services/permission_service.dart';
import 'package:lanmic/data/services/prefs_store.dart';
import 'package:lanmic/domain/link_stats.dart';
import 'package:lanmic/domain/phone_state.dart';
import 'package:lanmic/ui/features/mic/view_models/mic_view_model.dart';
import 'package:lanmic/ui/features/mic/views/mic_screen.dart';
import 'package:lanmic_protocol/lanmic_protocol.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../support/fakes.dart';

void main() {
  late FakeSession session;
  late FakeMic mic;
  late MicViewModel vm;
  late List<int> gains;

  Future<void> pump(WidgetTester t, {Size size = const Size(2400, 3000), double dpr = 3}) async {
    t.view.physicalSize = size;
    t.view.devicePixelRatio = dpr;
    addTearDown(t.view.reset);
    SharedPreferences.setMockInitialValues({});
    final log = <String>[];
    session = FakeSession(log)
      ..linkValue = const LinkSnapshot(
        phoneMs: 40, rttMs: 71, wifiMs: 36, tvMs: 218, delayMs: 294, quality: Quality.slow,
      );
    mic = FakeMic(log)..autoLevel = true;
    gains = [];
    vm = MicViewModel(
      session: session,
      mic: mic,
      prefs: PrefsStore(),
      perms: FakePerms(log)..mic.add(PermStatus.granted),
      fgs: FakeFgs(log),
      focus: FakeFocus(log),
      keepAwake: (_) {},
      now: DateTime.now,
      setMicGain: (db) async => gains.add(db),
    );
    await t.runAsync(vm.init);
    await t.pumpWidget(MaterialApp(home: MicScreen(viewModel: vm)));
  }

  Future<void> done(WidgetTester t) async {
    session.emit(PhoneState.disconnected);
    await t.pumpWidget(const SizedBox());
    vm.dispose();
  }

  testWidgets('boost row only while connected, live or lost', (t) async {
    await pump(t);
    expect(find.text('Mic boost'), findsNothing);
    for (final s in [PhoneState.connected, PhoneState.lost]) {
      session.emit(s);
      await t.pump();
      expect(find.text('Mic boost'), findsOneWidget, reason: '$s');
    }
    session.emit(PhoneState.disconnected);
    await t.pump();
    expect(find.text('Mic boost'), findsNothing);
    await done(t);
  });

  testWidgets('slider changes the boost, value shows a real minus, centre tick exists', (t) async {
    await pump(t);
    session.emit(PhoneState.connected);
    await t.pump();
    expect(find.text('0 dB'), findsOneWidget);
    expect(find.byKey(const ValueKey('boost-tick')), findsOneWidget);
    await t.runAsync(() => vm.setMicBoost(-6));
    await t.pump();
    expect(find.text('−6 dB'), findsOneWidget);
    final slider = t.widget<Slider>(find.byKey(const ValueKey('boost-slider')));
    expect((slider.min, slider.max, slider.divisions, slider.value), (-12, 12, 24, -6));
    await done(t);
  });

  testWidgets('double-tap on the value resets to 0 dB', (t) async {
    await pump(t);
    session.emit(PhoneState.connected);
    await t.runAsync(() => vm.setMicBoost(5));
    await t.pump();
    expect(find.text('+5 dB'), findsOneWidget);
    final v = find.byKey(const ValueKey('boost-value'));
    expect(t.getSize(v).width, greaterThanOrEqualTo(60));
    await t.tap(v);
    await t.pump(const Duration(milliseconds: 50));
    await t.tap(v);
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    expect(vm.micBoostDb, 0);
    expect(gains.last, 0);
    await done(t);
  });

  testWidgets('semantics read "Mic boost, plus 3 decibels"', (t) async {
    final h = t.ensureSemantics();
    await pump(t);
    session.emit(PhoneState.connected);
    await t.runAsync(() => vm.setMicBoost(3));
    await t.pump();
    expect(find.bySemanticsLabel(RegExp(r'Mic boost \+3 dB\. Double tap to reset')), findsOneWidget);
    final slider = t.widget<Slider>(find.byKey(const ValueKey('boost-slider')));
    expect(slider.semanticFormatterCallback!(3), 'plus 3 decibels');
    expect(find.bySemanticsLabel('Mic boost'), findsWidgets);
    h.dispose();
    await done(t);
  });

  testWidgets('limiting hint only while live and limiting', (t) async {
    await pump(t);
    session.emit(PhoneState.connected);
    await t.pump();
    mic.limitedPermille = 50;
    expect(find.text('Too loud, limiting'), findsNothing);
    vm.pressTalk();
    await t.runAsync(() => Future<void>.delayed(Duration.zero));
    await t.pump();
    mic.levels.add(0.1); // the stats poll's level event re-evaluates the hint
    await t.pump();
    expect(vm.state, PhoneState.live);
    expect(find.text('Too loud, limiting'), findsOneWidget);
    mic.limitedPermille = 0;
    mic.levels.add(0.1);
    await t.pump();
    expect(find.text('Too loud, limiting'), findsNothing);
    await done(t);
  });

  testWidgets('Disconnect fits at 412x915 live, Details open, limiting', (t) async {
    await pump(t, size: const Size(412, 915), dpr: 1);
    session.name = 'TV';
    session.emit(PhoneState.connected);
    await t.runAsync(() => vm.connect('192.168.1.42', '482917'));
    mic.limitedPermille = 50;
    vm.pressTalk();
    await t.runAsync(() => Future<void>.delayed(Duration.zero));
    await t.pump();
    mic.levels.add(0.1);
    await t.pump();
    expect(vm.state, PhoneState.live);
    expect(find.text('Too loud, limiting'), findsOneWidget);
    expect(t.getRect(find.text('Disconnect')).bottom, lessThanOrEqualTo(915));
    expect(t.getSize(find.byKey(const ValueKey('talk'))).height, greaterThanOrEqualTo(160));
    expect(t.state<ScrollableState>(find.byType(Scrollable).first).position.maxScrollExtent, 0);
    await done(t);
  });

  testWidgets('limiting hint has hysteresis: on above 20, off below 10 permille', (t) async {
    await pump(t);
    session.emit(PhoneState.connected);
    await t.pump();
    vm.pressTalk();
    await t.runAsync(() => Future<void>.delayed(Duration.zero));
    await t.pump();
    Future<bool> hint(int permille) async {
      mic.limitedPermille = permille;
      mic.levels.add(0.1);
      await t.pump();
      return find.text('Too loud, limiting').evaluate().isNotEmpty;
    }
    expect(await hint(15), isFalse);
    expect(await hint(25), isTrue);
    expect(await hint(15), isTrue); // between the thresholds: stays on
    expect(await hint(5), isFalse);
    expect(await hint(15), isFalse);
    await done(t);
  });

  testWidgets('boost row at 1.5x text: no overflow, row visible, Disconnect reachable', (t) async {
    t.view.physicalSize = const Size(412, 915);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    SharedPreferences.setMockInitialValues({});
    final log = <String>[];
    session = FakeSession(log)..name = 'TV';
    mic = FakeMic(log);
    vm = MicViewModel(
      session: session,
      mic: mic,
      prefs: PrefsStore(),
      perms: FakePerms(log)..mic.add(PermStatus.granted),
      fgs: FakeFgs(log),
      focus: FakeFocus(log),
      keepAwake: (_) {},
      now: DateTime.now,
    );
    await t.runAsync(vm.init);
    await t.runAsync(() => vm.setMicBoost(-12));
    await t.pumpWidget(
      MaterialApp(
        builder: (c, w) => MediaQuery(
          data: MediaQuery.of(c).copyWith(textScaler: const TextScaler.linear(1.5)),
          child: w!,
        ),
        home: MicScreen(viewModel: vm),
      ),
    );
    session.emit(PhoneState.connected);
    await t.pump();
    expect(t.takeException(), isNull); // no RenderFlex overflow
    expect(find.text('Mic boost'), findsOneWidget);
    expect(find.text('−12 dB'), findsOneWidget);
    expect(t.getSize(find.byKey(const ValueKey('boost-value'))).width, greaterThanOrEqualTo(60));
    expect(find.text('Disconnect'), findsOneWidget); // the screen scrolls at 1.5x
    await done(t);
  });
}
