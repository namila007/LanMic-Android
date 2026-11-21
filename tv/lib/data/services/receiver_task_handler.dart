import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:lanmic_protocol/lanmic_protocol.dart';
import 'package:pcm_out/pcm_out.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wifi_band/wifi_band.dart';

import '../../domain/receiver_engine.dart';
import '../../domain/receiver_status.dart';
import 'engine_factory.dart';
import 'voice_volume_store.dart';

const kReceiverNotificationTitle = 'LAN Mic receiver is running';
const kReceiverNotificationText = 'LAN Mic receiver is running';
const _statusInterval = Duration(milliseconds: 250); // at most 4 Hz to the UI

({AndroidNotificationOptions android, ForegroundTaskOptions task})
receiverServiceOptions() => (
  android: AndroidNotificationOptions(
    channelId: 'lanmic_receiver',
    channelName: 'LAN Mic receiver',
    channelImportance: NotificationChannelImportance.LOW,
    priority: NotificationPriority.LOW,
  ),
  task: ForegroundTaskOptions(
    eventAction:
        ForegroundTaskEventAction.nothing(), // the engine owns its timers
    autoRunOnBoot: true,
    allowWifiLock: true,
    allowWakeLock: true,
  ),
);

@pragma('vm:entry-point')
void startCallback() =>
    FlutterForegroundTask.setTaskHandler(ReceiverTaskHandler());

/// Runs in the service isolate: the only place the UDP socket is ever bound.
class ReceiverTaskHandler extends TaskHandler {
  ReceiverEngine? _engine;
  Timer? _report;
  StreamSubscription<String>? _sockLog;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload(); // the UI isolate may have just created the PIN
    const reader = WifiBandReader();
    var band = await reader.read(); // not polled: the TV's Wi-Fi rarely changes
    var retried = band != WifiBand.unknown;
    final engine = _engine = await buildReceiverEngine(
      prefs,
      wifiBand: () => band,
      // Booted before Wi-Fi was up: one more read when the first phone shows up.
      onPhoneActive: () {
        if (retried) return;
        retried = true;
        unawaited(reader.read().then((b) => band = b));
      },
    );
    unawaited(reader.setLowLatency(true));
    // Voice volume holds after a reboot without the UI: read the saved value here and apply it.
    try {
      await NativeReceiver().setPlaybackGainDb(await SharedPrefsVoiceVolumeStore(prefs).load());
    } on Object catch (e) {
      debugPrint('[lanmic] voice volume failed: $e');
    }
    _sockLog = engine.socketEvents.listen((e) => debugPrint('[lanmic] socket $e'));
    await engine.start();
    ReceiverStatus? sent;
    var ticks = 0, lastRx = 0;
    _report = Timer.periodic(_statusInterval, (_) {
      final s = engine.current;
      ticks++;
      if (ticks % 4 == 0) {
        final a = engine.stats;
        // 1 line/s: the TV-2 rx check, and (every 10th line) the TV-5 soak counters. Read with `adb logcat -s flutter`.
        debugPrint(
          '[lanmic] ${s.state.name} rx=${s.framesRx} (+${s.framesRx - lastRx}/s) '
          'dropped=${s.framesDropped} underruns=${s.underruns} '
          'delay=${s.delayMs} tv=${s.tvDelayMs} lost=${s.lostPermille}‰ '
          'jitter=${a?.jitterMs} band=${s.band.name} target=${a?.targetMs} depth=${a?.depthMs} '
          'out=${a?.latencyMs} mmap=${a?.mmap} burst=${a?.burst} xruns=${a?.xruns}',
        );
        lastRx = s.framesRx;
      }
      // Re-send every ~2 s so an activity opened later learns the current state.
      if (s == sent && ticks % 8 != 0) return;
      sent = s;
      FlutterForegroundTask.sendDataToMain(s.toMap());
    });
  }

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    _report?.cancel();
    unawaited(_sockLog?.cancel());
    unawaited(const WifiBandReader().setLowLatency(false));
    await _engine?.stop();
  }
}

/// UI-isolate view of the service's status messages.
class TaskStatusBridge implements ReceiverStatusSource {
  TaskStatusBridge() {
    FlutterForegroundTask.addTaskDataCallback(_onData);
  }

  final _ctl = StreamController<ReceiverStatus>.broadcast();

  void _onData(Object data) {
    if (data is Map) _ctl.add(ReceiverStatus.fromMap(data));
  }

  @override
  Stream<ReceiverStatus> get status => _ctl.stream;

  void dispose() {
    FlutterForegroundTask.removeTaskDataCallback(_onData);
    _ctl.close();
  }
}
