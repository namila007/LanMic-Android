import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_tv/receiver_screen.dart';

void main() {
  for (final s in TvState.values) {
    testWidgets('${s.name} shows "${s.label}"', (tester) async {
      await tester.pumpWidget(MaterialApp(home: ReceiverScreen(initialState: s)));
      expect(find.text(s.label), findsOneWidget);
    });
  }

  testWidgets('tap cycles listening -> connected', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ReceiverScreen()));
    await tester.tap(find.byType(ReceiverScreen));
    await tester.pump();
    expect(find.text('Phone connected'), findsOneWidget);
  });
}
