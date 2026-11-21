import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:lanmic/data/services/audio_focus.dart';
import 'package:lanmic/data/services/foreground_service.dart';
import 'package:lanmic/data/services/mic_service.dart';
import 'package:lanmic/data/services/native_packet_port.dart';
import 'package:lanmic/data/services/permission_service.dart';
import 'package:lanmic/data/services/prefs_store.dart';
import 'package:lanmic/data/services/session_service.dart';
import 'package:pcm_out/pcm_out.dart';
import 'package:lanmic/ui/features/mic/view_models/mic_view_model.dart';
import 'package:lanmic/ui/features/mic/views/mic_screen.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:wifi_band/wifi_band.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // The native receiver owns the one UDP socket (ephemeral port): HELLO/END leave from it, and native
  // audio is sent from a dup of the same fd, so the TV sees a single phone address.
  final receiver = NativeReceiver();
  try {
    await receiver.start(port: 0);
  } on Object catch (e) {
    debugPrint('receiver start failed: $e'); // the session then reports no response instead of a crash
  }
  final port = NativePacketPort(receiver);
  final capture = NativeCapture();
  final session = SessionService(port: port, setTarget: capture.setTarget);
  final vm = MicViewModel(
    session: session,
    mic: MicService(
      capture: capture,
      rebind: port.rebind,
      onStats: _logStats(session),
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
    setMicGain: capture.setGainDb,
  );
  await vm.init();
  runApp(LanMicApp(viewModel: vm));
}

/// Once a second: the debug lines for the seq-gap check and for calibrating the gate thresholds.
void Function(CaptureStats) _logStats(SessionService session) {
  var polls = 0, sent = 0, open = 0, frames = 0;
  double? min, max;
  return (s) {
    session.setPhoneLatency(s.inputLatencyMs);
    open += s.gateOpenFrames;
    frames += s.gateFrames;
    if (s.gateFrames > 0) {
      min = min == null || s.gateMinDb < min! ? s.gateMinDb : min;
      max = max == null || s.gateMaxDb > max! ? s.gateMaxDb : max;
    }
    if (++polls % 10 != 0) return;
    final l = session.helloInfo;
    debugPrint(
      'audio sent=${s.framesSent - sent} nextSeq=${s.framesSent + s.sendErrors} rtt=${l.rttMs} '
      'delay=${l.delayMs} sendGapMaxMs=${s.sendGapMaxMs} latencyMs=${s.inputLatencyMs} mmap=${s.mmap}',
    );
    debugPrint('gate open=$open/$frames min=${min?.round()}dB max=${max?.round()}dB');
    sent = s.framesSent;
    open = frames = 0;
    min = max = null;
  };
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
