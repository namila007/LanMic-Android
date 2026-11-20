import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanmic_tv/data/services/receiver_task_handler.dart';

void main() {
  test('notification says the receiver is running, low importance', () {
    final o = receiverServiceOptions();
    expect(kReceiverNotificationTitle, 'LAN Mic receiver is running');
    expect(kReceiverNotificationText, 'LAN Mic receiver is running');
    expect(o.android.channelImportance, NotificationChannelImportance.LOW);
  });

  test(
    'service starts on boot, holds wifi + wake locks, engine owns its timers',
    () {
      final t = receiverServiceOptions().task;
      expect(t.autoRunOnBoot, isTrue);
      expect(t.allowWifiLock, isTrue);
      expect(t.allowWakeLock, isTrue);
      expect(t.eventAction.type, ForegroundTaskEventType.nothing);
    },
  );
}
