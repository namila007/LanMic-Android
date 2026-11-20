import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:lanmic/data/services/audio_focus.dart';
import 'package:lanmic/data/services/foreground_service.dart';
import 'package:lanmic/data/services/mic_service.dart';
import 'package:lanmic/data/services/permission_service.dart';
import 'package:lanmic/data/services/prefs_store.dart';
import 'package:lanmic/data/services/session_service.dart';
import 'package:lanmic/data/services/udp_sender.dart';
import 'package:lanmic/domain/noise_gate.dart';
import 'package:lanmic/ui/features/mic/view_models/mic_view_model.dart';
import 'package:lanmic/ui/features/mic/views/mic_screen.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:wifi_band/wifi_band.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final session = SessionService(sender: await UdpSender.bind());
  final gate = NoiseGate();
  var frames = 0;
  final vm = MicViewModel(
    session: session,
    mic: MicService(
      source: RecordPcmSource(),
      onFrame: (f) {
        session.sendAudio(gate.process(f));
        // Once a second, for calibrating the gate thresholds on a real phone.
        if (++frames % 100 == 0) debugPrint(gate.takeStats());
      },
    ),
    prefs: PrefsStore(),
    perms: PluginPermissionService(),
    fgs: PluginForegroundService(),
    focus: PluginAudioFocus(),
    keepAwake: (on) =>
        unawaited(on ? WakelockPlus.enable() : WakelockPlus.disable()),
    now: DateTime.now,
    readBand: const WifiBandReader().read,
    setLowLatency: const WifiBandReader().setLowLatency,
  );
  await vm.init();
  runApp(LanMicApp(viewModel: vm));
}

class LanMicApp extends StatelessWidget {
  const LanMicApp({super.key, required this.viewModel});

  final MicViewModel viewModel;

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
    home: MicScreen(viewModel: viewModel),
  );
}
