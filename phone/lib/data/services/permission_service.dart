import 'package:permission_handler/permission_handler.dart';

enum PermStatus { granted, denied, permanentlyDenied }

abstract class PermissionService {
  Future<PermStatus> requestMic();
  Future<bool> requestNotifications();
  Future<void> openSettings();
}

class PluginPermissionService implements PermissionService {
  @override
  Future<PermStatus> requestMic() async {
    final s = await Permission.microphone.request();
    if (s.isGranted) return PermStatus.granted;
    return s.isPermanentlyDenied
        ? PermStatus.permanentlyDenied
        : PermStatus.denied;
  }

  @override
  Future<bool> requestNotifications() async =>
      (await Permission.notification.request()).isGranted;

  @override
  Future<void> openSettings() async {
    await openAppSettings();
  }
}
