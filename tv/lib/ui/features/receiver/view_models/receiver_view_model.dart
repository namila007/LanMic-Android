import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../../data/services/network_info_service.dart';
import '../../../../data/services/pin_store.dart';
import '../../../../data/services/voice_volume_store.dart';
import '../../../../domain/receiver_status.dart';

const _noNetwork = 'No network';

class ReceiverViewModel extends ChangeNotifier {
  ReceiverViewModel({
    required this.source,
    required this.net,
    required this.pins,
    this.stopService,
    this.volume,
    this.setPlaybackGain,
  });

  final ReceiverStatusSource source;
  final NetworkInfoService net;
  final PinStore pins;

  /// Stops the background receiver (UDP 5004 + audio). Home/Back leave it running.
  final Future<void> Function()? stopService;

  /// Where Voice volume is remembered (null: not persisted) and how it reaches the native player.
  final VoiceVolumeStore? volume;
  final Future<void> Function(int db)? setPlaybackGain;

  Future<void> exit() async => stopService?.call();

  ReceiverStatus _status = const ReceiverStatus(TvState.listening);
  String _address = _noNetwork;
  String _pin = '';
  StreamSubscription<ReceiverStatus>? _sub;
  Timer? _timer, _voiceTimer;
  int _voiceDb = 0;
  bool _voiceChanged = false;
  bool _disposed = false;

  ReceiverStatus get status => _status;
  TvState get state => _status.state;
  String get address => _address;
  String get pin => _pin;

  /// Voice volume in dB, -12..+12.
  int get voiceVolumeDb => _voiceDb;

  /// True for 2 s after a change (each change restarts it): the line is shown larger and highlighted.
  bool get voiceJustChanged => _voiceChanged;

  /// The Voice-volume limiter is working (the engine applies the hysteresis).
  bool get voiceLimited => _status.gainLimiting;

  Future<void> stepVoiceVolume(int delta) => _setVoice(_voiceDb + delta);

  Future<void> resetVoiceVolume() => _setVoice(0);

  Future<void> _setVoice(int db) async {
    if (_disposed) return;
    final next = db.clamp(-12, 12);
    final changed = next != _voiceDb;
    _voiceDb = next;
    _voiceChanged = true;
    _voiceTimer?.cancel();
    _voiceTimer = Timer(const Duration(seconds: 2), () {
      _voiceChanged = false;
      notifyListeners();
    });
    notifyListeners();
    if (!changed) return;
    await _applyGain(); // native first: what the screen shows is what the audio does
    _save(next);
    await _saving;
  }

  // Held keys come in bursts: at most one pref write in flight, and only the latest value waits behind it.
  int? _pendingSave;
  Future<void>? _saving;

  void _save(int db) {
    _pendingSave = db;
    _saving ??= _drainSaves();
  }

  Future<void> _drainSaves() async {
    try {
      while (_pendingSave != null) {
        final v = _pendingSave!;
        _pendingSave = null;
        try {
          await volume?.save(v);
        } on Object catch (e) {
          debugPrint('voice volume not saved: $e');
        }
      }
    } finally {
      _saving = null;
    }
  }

  Future<void> _applyGain() async {
    try {
      await setPlaybackGain?.call(_voiceDb);
    } on Object catch (e) {
      debugPrint('voice volume failed: $e');
    }
  }

  Future<void> init() async {
    _sub = source.status.listen((s) {
      final old = _status;
      final wasLimited = voiceLimited;
      _status = s;
      // Counters (rx, dropped, underruns) are not shown: skip the rebuild for them.
      if (s.state == old.state &&
          s.rttMs == old.rttMs &&
          s.delayMs == old.delayMs &&
          s.tvDelayMs == old.tvDelayMs &&
          s.lostPermille == old.lostPermille &&
          s.band == old.band &&
          voiceLimited == wasLimited) {
        return;
      }
      notifyListeners();
    });
    _voiceDb = await volume?.load() ?? 0;
    await _applyGain();
    _pin = (await pins.load()).toString();
    _address = await net.localIpv4() ?? _noNetwork;
    _timer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _refreshAddress(),
    );
    notifyListeners();
  }

  Future<void> _refreshAddress() async {
    final a = await net.localIpv4() ?? _noNetwork;
    if (a == _address) return;
    _address = a;
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _disposed = true;
    _timer?.cancel();
    _voiceTimer?.cancel();
    super.dispose();
  }
}
