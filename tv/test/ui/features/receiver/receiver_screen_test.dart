import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanmic_tv/data/services/network_info_service.dart';
import 'package:lanmic_tv/data/services/pin_store.dart';
import 'package:lanmic_tv/data/services/voice_volume_store.dart';
import 'package:lanmic_tv/domain/receiver_status.dart';
import 'package:lanmic_tv/ui/features/receiver/view_models/receiver_view_model.dart';
import 'package:lanmic_tv/ui/features/receiver/views/receiver_screen.dart';

class _Src implements ReceiverStatusSource {
  final ctl = StreamController<ReceiverStatus>.broadcast(sync: true);
  @override
  Stream<ReceiverStatus> get status => ctl.stream;
}

class _Net extends NetworkInfoService {
  @override
  Future<String?> localIpv4() async => '192.168.1.42';
}

class _Pins implements PinStore {
  @override
  Future<int> load() async => 482917;
}

void main() {
  late _Src src;
  late ReceiverViewModel vm;

  Future<void> pumpScreen(WidgetTester t) async {
    src = _Src();
    vm = ReceiverViewModel(source: src, net: _Net(), pins: _Pins());
    await t.runAsync(vm.init);
    await t.pumpWidget(MaterialApp(home: ReceiverScreen(vm: vm)));
    addTearDown(vm.dispose);
  }

  for (final s in TvState.values) {
    testWidgets('${s.name} shows "${s.label}"', (t) async {
      await pumpScreen(t);
      src.ctl.add(ReceiverStatus(s));
      await t.pump();
      expect(find.text(s.label), findsOneWidget);
      expect(
        find.byKey(const Key('eq')),
        s == TvState.receiving ? findsOneWidget : findsNothing,
      );
    });
  }

  testWidgets('stats line shows only when receiving or connected with a rtt', (
    t,
  ) async {
    await pumpScreen(t);
    expect(find.text('Lost audio'), findsNothing);
    src.ctl.add(const ReceiverStatus(TvState.connected));
    await t.pump();
    expect(find.text('Network'), findsNothing);
    src.ctl.add(const ReceiverStatus(TvState.connected, rttMs: 9));
    await t.pump();
    expect(find.text('Network'), findsOneWidget);
    expect(find.text('9 ms'), findsOneWidget);
    src.ctl.add(
      const ReceiverStatus(TvState.receiving, delayMs: 140, lostPermille: 3),
    );
    await t.pump();
    expect(find.text('about 140 ms'), findsOneWidget);
    expect(find.text('Lost audio'), findsOneWidget);
    expect(find.text('Network'), findsNothing);
  });

  testWidgets('shows the real address and PIN', (t) async {
    await pumpScreen(t);
    expect(find.text('192.168.1.42'), findsOneWidget);
    expect(find.text('482917'), findsOneWidget);
  });

  testWidgets('Exit stops the receiver service, then closes the app', (
    t,
  ) async {
    final calls = <String>[];
    src = _Src();
    vm = ReceiverViewModel(
      source: src,
      net: _Net(),
      pins: _Pins(),
      stopService: () async => calls.add('stopService'),
    );
    await t.runAsync(vm.init);
    await t.pumpWidget(MaterialApp(home: ReceiverScreen(vm: vm)));
    addTearDown(vm.dispose);
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (c) async {
        if (c.method == 'SystemNavigator.pop') calls.add(c.method);
        return null;
      },
    );
    await t.tap(find.text('Exit'));
    await t.pumpAndSettle();
    expect(calls, ['stopService', 'SystemNavigator.pop']);
  });

  testWidgets('D-pad select does not change state', (t) async {
    await pumpScreen(t);
    await t.sendKeyEvent(LogicalKeyboardKey.select);
    await t.tap(find.text('Listening'));
    await t.pump();
    expect(find.text('Listening'), findsOneWidget);
    expect(vm.state, TvState.listening);
    await t.pump(const Duration(seconds: 2)); // Select resets Voice volume: let its highlight end
  });

  group('voice volume', () {
    late List<int> gains;
    late int stored;

    Future<void> pumpVolume(WidgetTester t, {int db = 0}) async {
      gains = [];
      stored = db;
      src = _Src();
      vm = ReceiverViewModel(
        source: src,
        net: _Net(),
        pins: _Pins(),
        volume: _Vol(db, (v) => stored = v),
        setPlaybackGain: (v) async => gains.add(v),
      );
      await t.runAsync(vm.init);
      await t.pumpWidget(MaterialApp(home: ReceiverScreen(vm: vm)));
      addTearDown(vm.dispose);
    }

    Future<void> key(WidgetTester t, LogicalKeyboardKey k) async {
      await t.sendKeyEvent(k);
      await t.runAsync(() => Future<void>.delayed(Duration.zero));
      await t.pump();
    }

    testWidgets('always visible, even while listening', (t) async {
      await pumpVolume(t);
      expect(find.text('Voice volume'), findsOneWidget);
      expect(find.text('0 dB'), findsOneWidget);
      expect(find.byType(Container).evaluate().where((e) => e.widget.key.toString().contains('voice-step')).length, 25);
      await t.pump(const Duration(seconds: 3));
    });

    testWidgets('Up/Down step by 1 dB and the line is highlighted for 2 s', (t) async {
      await pumpVolume(t);
      final label = find.text('Voice volume');
      expect(t.widget<Text>(label).style!.fontSize, 32);
      await key(t, LogicalKeyboardKey.arrowUp);
      await key(t, LogicalKeyboardKey.arrowUp);
      await key(t, LogicalKeyboardKey.arrowDown);
      expect(find.text('+1 dB'), findsOneWidget);
      expect(gains, [0, 1, 2, 1]);
      expect(stored, 1);
      expect(t.widget<Text>(label).style!.fontSize, 40); // just changed
      expect(t.widget<Text>(find.text('+1 dB')).style!.color, const Color(0xFF2997FF));
      await t.pump(const Duration(milliseconds: 2100));
      expect(t.widget<Text>(label).style!.fontSize, 32);
    });

    testWidgets('a held key repeats', (t) async {
      await pumpVolume(t);
      await t.sendKeyDownEvent(LogicalKeyboardKey.arrowUp);
      await t.sendKeyRepeatEvent(LogicalKeyboardKey.arrowUp);
      await t.sendKeyRepeatEvent(LogicalKeyboardKey.arrowUp);
      await t.sendKeyUpEvent(LogicalKeyboardKey.arrowUp);
      await t.runAsync(() => Future<void>.delayed(Duration.zero));
      await t.pump();
      expect(vm.voiceVolumeDb, 3);
      await t.pump(const Duration(seconds: 3));
    });

    testWidgets('Select resets to 0 dB', (t) async {
      await pumpVolume(t, db: -5);
      expect(find.text('−5 dB'), findsOneWidget);
      await key(t, LogicalKeyboardKey.select);
      expect(vm.voiceVolumeDb, 0);
      expect(stored, 0);
      await t.pump(const Duration(seconds: 3));
    });

    testWidgets('Left/Right reach Exit and come back; Up/Down do not move focus', (t) async {
      await pumpVolume(t);
      final exit = find.widgetWithText(OutlinedButton, 'Exit');
      bool exitFocused() => Focus.of(t.element(find.text('Exit'))).hasFocus;
      expect(exitFocused(), isFalse);
      await key(t, LogicalKeyboardKey.arrowRight);
      expect(exitFocused(), isTrue);
      expect(exit, findsOneWidget);
      await key(t, LogicalKeyboardKey.arrowLeft);
      expect(exitFocused(), isFalse);
      await key(t, LogicalKeyboardKey.arrowDown);
      expect(exitFocused(), isFalse);
      await t.pump(const Duration(seconds: 3));
    });

    testWidgets('limiting shows "Voice limited" and the bar turns orange', (t) async {
      await pumpVolume(t, db: 12);
      expect(find.text('Voice limited'), findsNothing);
      src.ctl.add(const ReceiverStatus(TvState.receiving, gainLimiting: true));
      await t.pump();
      expect(find.text('Voice limited'), findsOneWidget);
      Color stepColor(int d) {
        final c = t.widget<Container>(find.byKey(Key('voice-step-$d')));
        return (c.decoration! as BoxDecoration).color!;
      }
      expect(stepColor(12), const Color(0xFFFF9F0A));
      expect(stepColor(0), Colors.white);
      expect(t.getSize(find.byKey(const Key('voice-step-0'))).height, 24);
      expect(t.getSize(find.byKey(const Key('voice-step-5'))).height, 14);
      expect(stepColor(-3).a, closeTo(0.18, 0.01));
      expect(
        find.byWidgetPredicate((w) => w is Semantics && w.properties.label == 'Voice volume plus 12 decibels. Voice limited.'),
        findsOneWidget,
      );
    });
  });
}

class _Vol implements VoiceVolumeStore {
  _Vol(this.value, this.onSave);
  final int value;
  final void Function(int) onSave;
  @override
  Future<int> load() async => value;
  @override
  Future<void> save(int db) async => onSave(db);
}
