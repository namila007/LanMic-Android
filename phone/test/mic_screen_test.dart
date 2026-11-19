import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanmic/mic_screen.dart';

void main() {
  for (final s in PhoneState.values) {
    testWidgets('$s shows its chip label', (tester) async {
      await tester.pumpWidget(MaterialApp(home: MicScreen(initialState: s)));
      expect(find.text(chipLabel(s)), findsOneWidget);
    });
  }

  testWidgets('PIN 000000 -> wrongPin, other PIN -> ready', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: MicScreen()));
    await tester.enterText(find.byType(TextField).last, '000000');
    await tester.tap(find.text('Connect'));
    await tester.pump();
    expect(find.text('Wrong PIN'), findsOneWidget);

    await tester.enterText(find.byType(TextField).last, '123456');
    await tester.tap(find.text('Connect'));
    await tester.pump();
    expect(find.text('Connected · Living Room'), findsOneWidget);
  });

  testWidgets('live timer counts up from 0:00', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: MicScreen(initialState: PhoneState.liveKeep)),
    );
    expect(find.text('0:00'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('0:03'), findsOneWidget);
  });

  testWidgets('hold mode: timer runs while held, stops on release', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: MicScreen(initialState: PhoneState.ready)),
    );
    final press = await tester.startGesture(
      tester.getCenter(find.text('HOLD TO TALK')),
    );
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('TALKING…'), findsOneWidget);
    expect(find.text('0:02'), findsOneWidget);
    await press.up();
    await tester.pump();
    expect(find.text('HOLD TO TALK'), findsOneWidget);
  });
}
