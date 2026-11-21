import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:pcm_out/pcm_out.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'data/services/network_info_service.dart';
import 'data/services/pin_store.dart';
import 'data/services/receiver_task_handler.dart';
import 'data/services/service_starter.dart';
import 'data/services/voice_volume_store.dart';
import 'ui/features/receiver/view_models/receiver_view_model.dart';
import 'ui/features/receiver/views/receiver_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.initCommunicationPort();
  final prefs = await SharedPreferences.getInstance();
  final pins = SharedPrefsPinStore(prefs);
  await pins.load(); // create the PIN before the service reads it
  final service = FlutterForegroundApi();
  await ServiceStarter(service).ensureRunning();
  final vm = ReceiverViewModel(
    source: TaskStatusBridge(),
    net: NetworkInfoService(),
    pins: pins,
    stopService: service.stop,
    volume: SharedPrefsVoiceVolumeStore(prefs),
    setPlaybackGain: NativeReceiver().setPlaybackGainDb,
  );
  await vm.init();
  runApp(TvApp(vm: vm));
}

class TvApp extends StatelessWidget {
  const TvApp({super.key, required this.vm});

  final ReceiverViewModel vm;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'LAN Mic Receiver',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      brightness: Brightness.dark,
      textTheme: GoogleFonts.interTextTheme(ThemeData.dark().textTheme)
          .apply(bodyColor: Colors.white, displayColor: Colors.white),
    ),
    home: ReceiverScreen(vm: vm),
  );
}
