import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanmic/data/services/permission_service.dart';
import 'package:lanmic/data/services/prefs_store.dart';
import 'package:lanmic/domain/phone_state.dart';
import 'package:lanmic/ui/features/mic/view_models/mic_view_model.dart';
import 'package:lanmic/ui/features/mic/views/mic_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../support/fakes.dart';

void main() {
  late FakeSession session;
  late FakePerms perms;
  late DateTime clock;
  late MicViewModel vm;

  Future<void> pump(
    WidgetTester t, {
    PermStatus perm = PermStatus.granted,
    TalkMode mode = TalkMode.hold,
    bool notifications = true,
  }) async {
    // Tall like a phone, so the stats card plus the talk button fit without scrolling.
    t.view.physicalSize = const Size(2400, 3000);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    SharedPreferences.setMockInitialValues({'mode': mode.name});
    final log = <String>[];
    session = FakeSession(log);
    perms = FakePerms(log)..mic.add(perm);
    clock = DateTime.utc(2026);
    vm = MicViewModel(
      session: session,
      mic: FakeMic(log)..autoLevel = true,
      prefs: PrefsStore(),
      perms: perms,
      fgs: FakeFgs(log)..notifications = notifications,
      focus: FakeFocus(log),
      keepAwake: (_) {},
      now: () => clock,
    );
    await t.runAsync(vm.init);
    await t.pumpWidget(MaterialApp(home: MicScreen(viewModel: vm)));
  }

  Future<void> toState(WidgetTester t, PhoneState s) async {
    await t.runAsync(() => vm.connect('192.168.1.42', '482917'));
    session.emit(s);
    await t.pump();
  }

  Future<void> close(WidgetTester t) async {
    session.emit(PhoneState.disconnected); // closes the mic and its timers
    await t.pumpWidget(const SizedBox());
    vm.dispose();
  }

  const chips = {
    PhoneState.disconnected: 'Not connected',
    PhoneState.connecting: 'Connecting…',
    PhoneState.connected: 'Connected · Living Room',
    PhoneState.noResponse: 'No response. Check IP and Wi-Fi.',
    PhoneState.wrongPin: 'Wrong PIN',
    PhoneState.lost: 'Connection lost. Retrying…',
  };
  for (final e in chips.entries) {
    testWidgets('chip for ${e.key.name}', (t) async {
      await pump(t);
      await toState(t, e.key);
      expect(find.text(e.value), findsOneWidget);
      await close(t);
    });
  }

  const idle = {
    PhoneState.disconnected: 'Connect first',
    PhoneState.noResponse: 'Connect first',
    PhoneState.wrongPin: 'Connect first',
    PhoneState.connected: 'HOLD TO TALK',
    PhoneState.lost: 'Reconnecting…',
  };
  for (final e in idle.entries) {
    testWidgets('talk label in ${e.key.name}', (t) async {
      await pump(t);
      await toState(t, e.key);
      expect(find.text(e.value), findsOneWidget);
      await close(t);
    });
  }

  testWidgets('keep mode ready label', (t) async {
    await pump(t, mode: TalkMode.keep);
    await toState(t, PhoneState.connected);
    expect(find.text('TAP TO TALK'), findsOneWidget);
    await close(t);
  });

  testWidgets('hold: TALKING… with timer, banner absent', (t) async {
    await pump(t);
    await toState(t, PhoneState.connected);
    final g = await t.startGesture(t.getCenter(find.text('HOLD TO TALK')));
    await t.pump();
    clock = clock.add(const Duration(seconds: 7));
    await t.pump(const Duration(seconds: 1));
    expect(find.text('TALKING…'), findsOneWidget);
    expect(find.text('0:07'), findsOneWidget);
    expect(find.text('MIC IS LIVE'), findsNothing);
    await g.up();
    await t.pump();
    expect(find.text('HOLD TO TALK'), findsOneWidget);
    await close(t);
  });

  testWidgets('keep: LIVE · TAP TO STOP, 0:42, banner', (t) async {
    await pump(t, mode: TalkMode.keep);
    await toState(t, PhoneState.connected);
    await t.tap(find.text('TAP TO TALK'));
    await t.pump();
    clock = clock.add(const Duration(seconds: 42));
    await t.pump(const Duration(seconds: 1));
    expect(find.text('LIVE · TAP TO STOP'), findsOneWidget);
    expect(find.text('0:42'), findsOneWidget);
    expect(find.text('MIC IS LIVE'), findsOneWidget);
    await t.tap(find.text('LIVE · TAP TO STOP'));
    await t.pump();
    expect(find.text('TAP TO TALK'), findsOneWidget);
    await close(t);
  });

  testWidgets('connect card hidden when connected, Disconnect visible', (
    t,
  ) async {
    await pump(t);
    expect(find.text('Connect'), findsOneWidget);
    await toState(t, PhoneState.connected);
    expect(find.text('Connect'), findsNothing);
    expect(find.text('Disconnect'), findsOneWidget);
    await close(t);
  });

  testWidgets(
    'hold: sliding the finger off keeps it live; lift and cancel stop',
    (t) async {
      await pump(t);
      await toState(t, PhoneState.connected);
      final g = await t.startGesture(t.getCenter(find.text('HOLD TO TALK')));
      await t.pump();
      expect(find.text('TALKING…'), findsOneWidget);
      await g.moveTo(const Offset(-500, -500));
      await t.pump();
      expect(find.text('TALKING…'), findsOneWidget);
      await g.up();
      await t.pump();
      expect(find.text('HOLD TO TALK'), findsOneWidget);

      final g2 = await t.startGesture(t.getCenter(find.text('HOLD TO TALK')));
      await t.pump();
      await g2.cancel();
      await t.pump();
      expect(find.text('HOLD TO TALK'), findsOneWidget);
      await close(t);
    },
  );

  testWidgets('keep: holding does nothing until a tap completes', (t) async {
    await pump(t, mode: TalkMode.keep);
    await toState(t, PhoneState.connected);
    final g = await t.startGesture(t.getCenter(find.text('TAP TO TALK')));
    await t.pump(const Duration(seconds: 1));
    expect(find.text('TAP TO TALK'), findsOneWidget);
    await g.cancel();
    await t.pump();
    expect(find.text('TAP TO TALK'), findsOneWidget);
    await close(t);
  });

  testWidgets('rotation keeps state and timer', (t) async {
    await pump(t, mode: TalkMode.keep);
    await toState(t, PhoneState.connected);
    await t.tap(find.text('TAP TO TALK'));
    await t.pump();
    clock = clock.add(const Duration(seconds: 3));
    t.view.physicalSize = const Size(3000, 1500);
    addTearDown(t.view.reset);
    await t.pump(const Duration(seconds: 1));
    expect(find.text('LIVE · TAP TO STOP'), findsOneWidget);
    expect(find.text('0:03'), findsOneWidget);
    t.view.physicalSize = const Size(1500, 3000);
    await t.pump();
    expect(find.text('0:03'), findsOneWidget);
    await close(t);
  });

  testWidgets('mic denied: button disabled, Open settings works', (t) async {
    await pump(t, perm: PermStatus.permanentlyDenied);
    await toState(t, PhoneState.connected);
    await t.tap(find.text('HOLD TO TALK'));
    await t.pump();
    expect(find.text('TALKING…'), findsNothing);
    await t.tap(find.text('Open settings'));
    expect(perms.opened, 1);
    await close(t);
  });

  testWidgets('paused by a call banner clears on next press', (t) async {
    await pump(t);
    await toState(t, PhoneState.connected);
    final g = await t.startGesture(t.getCenter(find.text('HOLD TO TALK')));
    await t.pump();
    vm.onInterruption(true);
    await t.pump();
    expect(find.text('Paused by a call'), findsOneWidget);
    await g.up();
    final g2 = await t.startGesture(t.getCenter(find.text('HOLD TO TALK')));
    await t.pump();
    expect(find.text('Paused by a call'), findsNothing);
    await g2.up();
    await close(t);
  });

  testWidgets('first-run rationale shows before the system prompt', (t) async {
    await pump(t, perm: PermStatus.denied);
    expect(
      find.text('LAN Mic needs the microphone to send your voice to the TV.'),
      findsOneWidget,
    );
    await close(t);
  });

  testWidgets('invalid input shows the error on the card', (t) async {
    await pump(t);
    await t.enterText(find.byType(TextField).first, 'tv.local');
    await t.tap(find.text('Connect'));
    await t.pump();
    expect(find.textContaining('TV address'), findsWidgets);
    await close(t);
  });

  testWidgets('haptics: go live buzzes once, keep stop twice', (t) async {
    final buzz = <MethodCall>[];
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (c) async {
        if (c.method == 'HapticFeedback.vibrate') buzz.add(c);
        return null;
      },
    );
    addTearDown(
      () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await pump(t, mode: TalkMode.keep);
    await toState(t, PhoneState.connected);
    await t.tap(find.text('TAP TO TALK'));
    await t.pump();
    expect(buzz.length, 1);
    await t.tap(find.text('LIVE · TAP TO STOP'));
    await t.pump();
    expect(buzz.length, 3);
    await close(t);
  });

  testWidgets('keep with notifications off shows the Stop-control warning', (
    t,
  ) async {
    await pump(t, mode: TalkMode.keep, notifications: false);
    await toState(t, PhoneState.connected);
    await t.tap(find.text('TAP TO TALK'));
    await t.pump();
    await t.pump();
    expect(
      find.text("Notifications are off. The Stop control won't show."),
      findsOneWidget,
    );
    await close(t);
  });

  testWidgets('app going to background closes hold', (t) async {
    await pump(t);
    await toState(t, PhoneState.connected);
    final g = await t.startGesture(t.getCenter(find.text('HOLD TO TALK')));
    await t.pump();
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await t.pump();
    expect(find.text('HOLD TO TALK'), findsOneWidget);
    await g.up();
    await close(t);
  });
}
