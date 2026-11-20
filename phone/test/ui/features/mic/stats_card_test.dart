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

const _full = LinkSnapshot(
  phoneMs: 40,
  rttMs: 9,
  wifiMs: 5,
  tvMs: 95,
  delayMs: 140,
  lostPermille: 3,
  jitterMs: 2,
  tvBand: WifiBand.ghz5,
  quality: Quality.ok,
);

void main() {
  late FakeSession session;
  late MicViewModel vm;

  Future<void> pump(WidgetTester t, {LinkSnapshot? link, bool connect = true}) async {
    t.view.physicalSize = const Size(2400, 3000);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    SharedPreferences.setMockInitialValues({});
    final log = <String>[];
    session = FakeSession(log);
    if (link != null) session.linkValue = link;
    vm = MicViewModel(
      session: session,
      mic: FakeMic(log),
      prefs: PrefsStore(),
      perms: FakePerms(log)..mic.add(PermStatus.granted),
      fgs: FakeFgs(log),
      focus: FakeFocus(log),
      keepAwake: (_) {},
      now: DateTime.now,
      readBand: () async => WifiBand.ghz2_4,
    );
    await t.runAsync(vm.init);
    await t.pumpWidget(MaterialApp(home: MicScreen(viewModel: vm)));
    if (connect) {
      session.emit(PhoneState.connected);
      await t.pump();
    }
  }

  Future<void> done(WidgetTester t) async {
    session.emit(PhoneState.disconnected);
    await t.pumpWidget(const SizedBox());
    vm.dispose();
  }

  testWidgets('card hidden when not connected', (t) async {
    await pump(t, connect: false);
    expect(find.text('Delay'), findsNothing);
    await done(t);
  });

  testWidgets('Measuring… before first RTT', (t) async {
    await pump(t);
    expect(find.text('Measuring…'), findsOneWidget);
    await done(t);
  });

  testWidgets('Talk to measure before TV delay', (t) async {
    await pump(t, link: const LinkSnapshot(phoneMs: 40, rttMs: 9, wifiMs: 5));
    expect(find.text('Talk to measure'), findsOneWidget);
    await done(t);
  });

  testWidgets('full values and OK', (t) async {
    await pump(t, link: _full);
    expect(find.text('about 140 ms'), findsOneWidget);
    expect(find.text('OK'), findsOneWidget);
    expect(find.text('9 ms'), findsOneWidget);
    expect(find.text('0.3%'), findsOneWidget);
    expect(find.text('~40 ms'), findsOneWidget);
    expect(find.text('5 GHz'), findsOneWidget);
    await done(t);
  });

  testWidgets('old TV hint', (t) async {
    await pump(
      t,
      link: const LinkSnapshot(phoneMs: 40, rttMs: 9, wifiMs: 5, tvTooOld: true),
    );
    expect(find.text('Update the TV app to see the full delay'), findsOneWidget);
    await done(t);
  });

  testWidgets('lost shows a dash when unknown', (t) async {
    await pump(t, link: const LinkSnapshot(phoneMs: 40, rttMs: 9));
    expect(find.text('Lost audio'), findsOneWidget);
    expect(find.text('—'), findsWidgets);
    await done(t);
  });

  testWidgets('lost shows — greyed', (t) async {
    await pump(t, link: _full);
    session.emit(PhoneState.lost);
    await t.pump();
    expect(find.text('about 140 ms'), findsNothing);
    expect(find.text('9 ms'), findsNothing);
    expect(find.text('0.3%'), findsNothing);
    expect(find.text('OK'), findsNothing);
    final dashes = find.text('—');
    expect(dashes, findsWidgets);
    for (var i = 0; i < 3; i++) {
      expect(t.widget<Text>(dashes.at(i)).style!.color, const Color(0xFF333333));
    }
    await done(t);
  });

  testWidgets('Details toggle hides the grid and moves the talk button up', (t) async {
    await pump(t, link: _full);
    final talk = find.bySemanticsLabel(RegExp('Talk button'));
    final before = t.getTopLeft(talk).dy;
    expect(find.text('Jitter'), findsOneWidget);
    expect(find.bySemanticsLabel('Details'), findsOneWidget);
    await t.tap(find.text('▾ Details'));
    await t.pump();
    expect(find.text('Jitter'), findsNothing);
    expect(find.text('▸ Details'), findsOneWidget);
    expect(t.getTopLeft(talk).dy, lessThan(before));
    await done(t);
  });

  testWidgets('semantics label', (t) async {
    final h = t.ensureSemantics();
    await pump(t, link: _full);
    expect(
      find.bySemanticsLabel(
        'Delay about 140 milliseconds, OK. Network 9 milliseconds. Lost audio 0.3 percent.',
      ),
      findsOneWidget,
    );
    h.dispose();
    await done(t);
  });

  testWidgets('phoneBand is read on connect', (t) async {
    await pump(t, link: _full);
    await t.runAsync(() => Future<void>.delayed(Duration.zero));
    await t.pump();
    expect(vm.phoneBand, WifiBand.ghz2_4);
    expect(find.text('2.4 GHz'), findsOneWidget);
    await done(t);
  });
}
