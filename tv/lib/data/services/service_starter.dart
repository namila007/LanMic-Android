import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'receiver_task_handler.dart';

abstract class ForegroundServiceApi {
  Future<bool> isRunning();
  Future<void> start();
  Future<void> stop();
}

class FlutterForegroundApi implements ForegroundServiceApi {
  @override
  Future<bool> isRunning() => FlutterForegroundTask.isRunningService;

  @override
  Future<void> start() async {
    final o = receiverServiceOptions();
    FlutterForegroundTask.init(
      androidNotificationOptions: o.android,
      iosNotificationOptions: IOSNotificationOptions(),
      foregroundTaskOptions: o.task,
    );
    final r = await FlutterForegroundTask.startService(
      serviceTypes: [ForegroundServiceTypes.mediaPlayback],
      notificationTitle: kReceiverNotificationTitle,
      notificationText: kReceiverNotificationText,
      callback: startCallback,
    );
    if (r is ServiceRequestFailure) throw r.error;
  }

  /// The service's onDestroy stops the engine: socket closed, AudioTrack released.
  @override
  Future<void> stop() async {
    final r = await FlutterForegroundTask.stopService();
    if (r is ServiceRequestFailure) throw r.error;
  }
}

class ServiceStarter {
  ServiceStarter(this.api);

  final ForegroundServiceApi api;
  Future<void>? _pending;

  /// Idempotent: never starts a second service (a second one would bind port 5004 twice).
  Future<void> ensureRunning() =>
      _pending ??= _run().whenComplete(() => _pending = null);

  Future<void> _run() async {
    if (!await api.isRunning()) await api.start();
  }
}
