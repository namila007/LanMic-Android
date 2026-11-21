import 'dart:async';
import 'dart:io';

import 'package:lanmic/data/services/audio_focus.dart';
import 'package:lanmic/data/services/foreground_service.dart';
import 'package:lanmic/data/services/permission_service.dart';
import 'package:lanmic/data/services/session_service.dart';
import 'package:lanmic/domain/link_stats.dart';
import 'package:lanmic/domain/phone_state.dart';

import 'package:lanmic/data/services/mic_service.dart';

class FakeSession implements SessionService {
  FakeSession(this.log);
  final List<String> log;
  final _c = StreamController<PhoneState>.broadcast(sync: true);
  PhoneState _s = PhoneState.disconnected;

  void emit(PhoneState s) {
    _s = s;
    _c.add(s);
  }

  @override
  Stream<PhoneState> get states => _c.stream;
  @override
  PhoneState get state => _s;
  @override
  String? get tvName => name;
  String name = 'Living Room'; // tests may shorten it: Ahem glyphs are wide
  @override
  Future<void> connect(InternetAddress tv, int pin) async =>
      log.add('connect ${tv.address} $pin');
  @override
  Future<void> disconnect() async {
    log.add('disconnect');
    emit(PhoneState.disconnected);
  }

  final _link = StreamController<LinkSnapshot>.broadcast(sync: true);
  LinkSnapshot linkValue = const LinkSnapshot(phoneMs: kPhoneDelayEstimateMs);
  @override
  LinkSnapshot get link => linkValue;
  @override
  Stream<LinkSnapshot> get linkUpdates => _link.stream;
  void emitLink(LinkSnapshot v) {
    linkValue = v;
    _link.add(v);
  }

  @override
  void Function() endSender() => () => log.add('end');
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class FakeMic implements Mic {
  FakeMic(this.log);
  final List<String> log;
  Completer<void>? openGate;
  Completer<void>? closeGate; // holds close() open: the capture is still draining
  bool failOpen = false;
  bool autoLevel =
      false; // emit PCM-like activity so the stall watchdog stays quiet
  Timer? _auto;
  bool _open = false;

  @override
  bool get isOpen => _open;
  @override
  Object? error;
  final levels = StreamController<double>.broadcast(sync: true);
  @override
  Stream<double> get level => levels.stream;

  @override
  Future<void> open() async {
    log.add('mic.open');
    await openGate?.future;
    _open = !failOpen && !_closedWhileOpening;
    _closedWhileOpening = false;
    if (_open && autoLevel) {
      _auto = Timer.periodic(
        const Duration(milliseconds: 100),
        (_) => levels.add(0.1),
      );
    }
  }

  bool _closedWhileOpening = false;

  @override
  Future<void> close() async {
    log.add('mic.close');
    _auto?.cancel();
    _closedWhileOpening = openGate != null && !(openGate!.isCompleted);
    _open = false;
    await closeGate?.future;
    if (closeGate != null) log.add('mic.closed');
  }

}

class FakePerms implements PermissionService {
  FakePerms(this.log);
  final List<String> log;
  final mic = <FutureOr<PermStatus>>[]; // consumed in order; last one repeats
  bool notif = true;
  int opened = 0;

  @override
  Future<PermStatus> requestMic() async {
    log.add('perm.mic');
    final r = mic.length > 1 ? mic.removeAt(0) : mic.first;
    return r;
  }

  @override
  Future<bool> requestNotifications() async {
    log.add('perm.notif');
    return notif;
  }

  @override
  Future<void> openSettings() async => opened++;
}

class FakeFgs implements ForegroundService {
  FakeFgs(this.log);
  final List<String> log;
  final stopController = StreamController<void>.broadcast(sync: true);
  bool failStart = false;
  bool notifications = true;

  @override
  Future<void> start({required String tvName}) async {
    log.add('fgs.start $tvName');
    if (failStart) throw StateError('fgs');
  }

  @override
  Future<void> stop() async => log.add('fgs.stop');
  @override
  Stream<void> get stopPressed => stopController.stream;
  @override
  Future<bool> get notificationsAllowed async => notifications;
}

class FakeFocus implements AudioFocus {
  FakeFocus(this.log);
  final List<String> log;
  final interrupt = StreamController<void>.broadcast(sync: true);

  @override
  Future<void> activate() async => log.add('focus.on');
  @override
  Future<void> deactivate() async => log.add('focus.off');
  @override
  Stream<void> get interruptions => interrupt.stream;
}
