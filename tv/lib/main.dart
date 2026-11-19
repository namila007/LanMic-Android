import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'receiver_screen.dart';

void main() => runApp(const TvApp());

class TvApp extends StatelessWidget {
  const TvApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'LAN Mic Receiver',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      brightness: Brightness.dark,
      textTheme: GoogleFonts.interTextTheme(ThemeData.dark().textTheme)
          .apply(bodyColor: Colors.white, displayColor: Colors.white),
    ),
    home: const ReceiverScreen(),
  );
}
