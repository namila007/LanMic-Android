import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'mic_screen.dart';

void main() => runApp(const LanMicApp());

class LanMicApp extends StatelessWidget {
  const LanMicApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'LAN Mic',
    debugShowCheckedModeBanner: false,
    themeMode: ThemeMode.system,
    // Design font is SF Pro with Inter fallback; Android has no SF, so Inter.
    theme: ThemeData(
      brightness: Brightness.light,
      scaffoldBackgroundColor: const Color(0xFFF5F5F7),
      textTheme: GoogleFonts.interTextTheme(ThemeData.light().textTheme),
    ),
    darkTheme: ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: const Color(0xFF272729),
      textTheme: GoogleFonts.interTextTheme(ThemeData.dark().textTheme),
    ),
    home: const MicScreen(),
  );
}
