import 'package:flutter/material.dart';

void main() => runApp(const TvApp());

class TvApp extends StatelessWidget {
  const TvApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Karaoke TV',
        theme: ThemeData.dark(useMaterial3: true),
        home: const Scaffold(body: Center(child: Text('Karaoke TV', style: TextStyle(fontSize: 48)))),
      );
}
