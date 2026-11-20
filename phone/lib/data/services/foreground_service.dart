import 'dart:async';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Keeps the mic alive while the app is in the background (Keep mode only).
abstract class ForegroundService {
  /// Throws when the service cannot start.
  Future<void> start({required String tvName});
  Future<void> stop();
  Stream<void> get stopPressed;
  Future<bool> get notificationsAllowed;
}

const _stopId = 'stop';

// Runs in the plugin's isolate; only relays the notification button.
@pragma('vm:entry-point')
void foregroundStartCallback() =>
    FlutterForegroundTask.setTaskHandler(_RelayHandler());

class _RelayHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}

  @override
  void onNotificationButtonPressed(String id) {
    if (id == _stopId) FlutterForegroundTask.sendDataToMain(_stopId);
  }
}

class PluginForegroundService implements ForegroundService {
  PluginForegroundService() {
    FlutterForegroundTask.initCommunicationPort();
    FlutterForegroundTask.addTaskDataCallback(
      (data) => data == _stopId ? _stop.add(null) : null,
    );
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'lanmic_mic',
        channelName: 'Live microphone',
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  final _stop = StreamController<void>.broadcast();

  @override
  Stream<void> get stopPressed => _stop.stream;

  @override
  Future<bool> get notificationsAllowed async =>
      await FlutterForegroundTask.checkNotificationPermission() ==
      NotificationPermission.granted;

  @override
  Future<void> start({required String tvName}) async {
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
    }
    final r = await FlutterForegroundTask.startService(
      serviceTypes: [ForegroundServiceTypes.microphone],
      notificationTitle: 'Mic is live → $tvName',
      notificationText: 'Tap Stop to turn the microphone off.',
      notificationButtons: [
        const NotificationButton(id: _stopId, text: 'Stop'),
      ],
      callback: foregroundStartCallback,
    );
    if (r is ServiceRequestFailure) throw r.error;
  }

  @override
  Future<void> stop() async {
    await FlutterForegroundTask.stopService();
  }
}
