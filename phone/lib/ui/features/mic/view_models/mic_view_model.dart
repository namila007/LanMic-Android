import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:lanmic/data/services/audio_focus.dart';
import 'package:lanmic/data/services/foreground_service.dart';
import 'package:lanmic/data/services/mic_service.dart';
import 'package:lanmic/data/services/permission_service.dart';
import 'package:lanmic/data/services/prefs_store.dart';
import 'package:lanmic/data/services/session_service.dart';
import 'package:lanmic/domain/input_validation.dart';
import 'package:lanmic/domain/link_stats.dart';
import 'package:lanmic/domain/phone_state.dart';
import 'package:lanmic/domain/talk_gate.dart';
import 'package:lanmic_protocol/lanmic_protocol.dart';

// RMS of an all-zero chunk is 0; one LSB of noise is already ~3e-5.
const _silentLevel = 1e-5;

class MicViewModel extends ChangeNotifier {
  MicViewModel({
    required this.session,
    required this.mic,
    required this.prefs,
    required this.perms,
    required this.fgs,
    required this.focus,
    required this.keepAwake,
    required this.now,
    Future<WifiBand> Function()? readBand,
    void Function(bool)? setLowLatency,
  }) : _readBand = readBand ?? (() async => WifiBand.unknown),
       _setLowLatency = setLowLatency ?? ((_) {}) {
    _gate = TalkGate(
      onOpen: _onOpen,
      onClose: _onClose,
      sendEnd: session.sendEnd,
    );
    _sub = session.states.listen(_onSession);
    _linkSub = session.linkUpdates.listen((_) => notifyListeners());
    _focusSub = focus.interruptions.listen((_) => onInterruption(true));
    _stopSub = fgs.stopPressed.listen((_) {
      _gate.stop();
      notifyListeners();
    });
  }

  final SessionService session;
  final MicService mic;
  final PrefsStore prefs;
  final PermissionService perms;
  final ForegroundService fgs;
  final AudioFocus focus;
  final void Function(bool) keepAwake;
  final DateTime Function() now;
  final Future<WifiBand> Function() _readBand;
  final void Function(bool) _setLowLatency;
  late final TalkGate _gate;
  late final StreamSubscription<PhoneState> _sub;
  late final StreamSubscription<LinkSnapshot> _linkSub;
  late final StreamSubscription<void> _stopSub;
  late final StreamSubscription<void> _focusSub;
  StreamSubscription<double>? _levelSub;
  Timer? _stall;
  bool _serviceUp = false;
  bool notificationsOff = false;
  WifiBand phoneBand = WifiBand.unknown;
  bool detailsOpen = true; // in memory only
  bool _wasConnected = false;
  bool _disposed = false;

  String? savedIp;
  String? ipError;
  String? micError;
  PermStatus _micPerm = PermStatus.denied;
  bool _pausedByCall = false;
  bool _pressed = false;
  bool _awake = false;
  int _openToken = 0;
  DateTime _openedAt = DateTime.fromMillisecondsSinceEpoch(0);

  PhoneState get state => session.state == PhoneState.connected && _gate.isOpen
      ? PhoneState.live
      : session.state;
  TalkMode get mode => _gate.mode;
  String? get tvName => session.tvName;
  Duration get liveFor =>
      state == PhoneState.live ? now().difference(_openedAt) : Duration.zero;
  PermStatus get micPerm => _micPerm;
  bool get pausedByCall => _pausedByCall;
  Stream<double> get level => mic.level;

  /// Null unless connected, live or lost.
  LinkSnapshot? get link =>
      session.state == PhoneState.connected || session.state == PhoneState.lost
      ? session.link
      : null;

  void toggleDetails() {
    detailsOpen = !detailsOpen;
    notifyListeners();
  }

  Future<void> init() async {
    final p = await prefs.load();
    savedIp = p.ip;
    _gate.setMode(p.mode);
    notifyListeners();
  }

  Future<void> connect(String ip, String pinText) async {
    final pin = parsePin(pinText);
    if (!isValidIpv4(ip)) {
      ipError = 'Enter the TV address, like 192.168.1.42.';
    } else if (pin == null) {
      ipError = 'The PIN is 6 digits.';
    } else {
      ipError = null;
    }
    notifyListeners();
    if (ipError != null || pin == null) return;
    await prefs.save(ip: ip);
    _micPerm = await perms.requestMic();
    if (_micPerm == PermStatus.granted) await perms.requestNotifications();
    notifyListeners();
    await session.connect(InternetAddress(ip), pin);
  }

  Future<void> disconnect() async {
    _gate.stop();
    await session.disconnect();
    _pausedByCall = false;
  }

  void setMode(TalkMode m) {
    _gate.setMode(m);
    unawaited(prefs.save(mode: m));
    notifyListeners();
  }

  void pressTalk() {
    if (!_gate.enabled) return;
    _pressed = true;
    _withMic(_gate.press);
  }

  void releaseTalk() {
    _pressed = false;
    _gate.release();
  }

  void tapTalk() {
    if (!_gate.enabled) return;
    _withMic(_gate.tap);
  }

  void onInterruption(bool begin) {
    if (!begin) return; // resume is manual
    if (_gate.isOpen) _pausedByCall = true;
    _gate.interrupted();
    notifyListeners();
  }

  void onLifecycle(AppLifecycleState s) {
    if (s == AppLifecycleState.paused || s == AppLifecycleState.hidden) {
      _gate.backgrounded();
      notifyListeners();
    }
  }

  Future<void> openSettings() => perms.openSettings();

  // Runs [act] once the mic permission is granted; a press released while the
  // permission dialog was up does nothing.
  void _withMic(void Function() act) {
    _pausedByCall = false;
    switch (_micPerm) {
      case PermStatus.granted:
        act();
      case PermStatus.permanentlyDenied:
        break;
      case PermStatus.denied:
        unawaited(_askThen(act));
    }
  }

  Future<void> _askThen(void Function() act) async {
    _micPerm = await perms.requestMic();
    notifyListeners();
    if (_micPerm != PermStatus.granted) return;
    if (_gate.mode == TalkMode.hold && !_pressed) return;
    act();
  }

  void _onOpen() {
    _openedAt = now();
    micError = null;
    session.beginTalk();
    unawaited(_start(++_openToken));
    notifyListeners();
  }

  // Keep mode needs the foreground service first: never live without it.
  Future<void> _start(int token) async {
    if (_gate.mode == TalkMode.keep) {
      try {
        await fgs.start(tvName: tvName ?? 'TV');
        _serviceUp = true;
      } on Object {
        return _fail(token, 'Could not start the background service.');
      }
      if (token != _openToken) return _stopService();
      notificationsOff = !await fgs.notificationsAllowed;
      notifyListeners();
    }
    try {
      await focus.activate();
    } on Object {
      // Focus is only for call detection; the silence watchdog still covers it.
    }
    if (token != _openToken) return unawaited(focus.deactivate());
    await mic.open();
    if (token != _openToken || !_gate.isOpen) return;
    if (!mic.isOpen) return _fail(token, 'Could not start the microphone.');
    _watchForStall(token);
  }

  void _fail(int token, String msg) {
    if (token != _openToken) return;
    micError = msg;
    _gate.interrupted();
    notifyListeners();
  }

  // Fallback when no focus callback arrives. Android 10+ keeps delivering
  // zero-filled PCM during a call, so only audible chunks re-arm the timer.
  void _watchForStall(int token) {
    void arm() {
      _stall?.cancel();
      _stall = Timer(const Duration(seconds: 1), () {
        if (token != _openToken) return;
        micError = 'The microphone went silent. Tap to talk again.';
        _gate.interrupted();
        notifyListeners();
      });
    }

    arm();
    _levelSub = mic.level.listen((l) {
      if (l > _silentLevel) arm();
    });
  }

  void _stopWatch() {
    _stall?.cancel();
    unawaited(_levelSub?.cancel());
    _levelSub = null;
  }

  void _stopService() {
    if (!_serviceUp) return;
    _serviceUp = false;
    unawaited(fgs.stop());
  }

  void _onClose() {
    _openToken++;
    _stopWatch();
    unawaited(mic.close());
    unawaited(focus.deactivate());
    _stopService();
    notifyListeners();
  }

  // Read once per arrival at connected: the phone's Wi-Fi rarely changes mid-session.
  Future<void> _readPhoneBand() async {
    try {
      phoneBand = await _readBand();
    } on Object {
      phoneBand = WifiBand.unknown;
    }
    if (!_disposed) notifyListeners();
  }

  void _onSession(PhoneState s) {
    final connected = s == PhoneState.connected;
    if (connected && !_wasConnected) unawaited(_readPhoneBand());
    _wasConnected = connected;
    _gate.enabled = s == PhoneState.connected;
    final awake = s == PhoneState.connected || s == PhoneState.lost;
    if (awake != _awake) {
      _awake = awake;
      keepAwake(awake);
      _setLowLatency(awake);
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    if (_awake) _setLowLatency(false);
    unawaited(_sub.cancel());
    unawaited(_linkSub.cancel());
    unawaited(_stopSub.cancel());
    unawaited(_focusSub.cancel());
    _stopWatch();
    super.dispose();
  }
}
