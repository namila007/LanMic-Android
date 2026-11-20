import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanmic_tv/data/services/network_info_service.dart';
import 'package:lanmic_tv/data/services/pin_store.dart';
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
  });
}
