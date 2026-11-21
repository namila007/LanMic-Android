import 'dart:async';
import 'dart:developer' as dev;
import 'dart:typed_data';

import 'package:lanmic_protocol/lanmic_protocol.dart';

import 'audio_engine.dart';
import 'loss_meter.dart';
import 'receiver_status.dart';
import 'session_registry.dart';

export 'audio_engine.dart' show Datagram;

const _audioTimeout = 500; // ms since the last accepted AUDIO before "receiving" ends
const _housekeeping = Duration(milliseconds: 100);
const _statsPoll = Duration(milliseconds: 250);
const _bandCopies = 3; // the band goes out in the first few STATS only; 3 copies survive UDP loss
const _delaySamples = 5;

WifiBand _unknownBand() => WifiBand.unknown;

/// Protocol brain: registry, PIN, ACK/REJECT and STATS. Audio runs natively; this polls its numbers.
class ReceiverEngine implements ReceiverStatusSource {
  ReceiverEngine({
    required this.audio,
    required this.registry,
    required this.now,
    this.wifiBand = _unknownBand,
    this.onPhoneActive,
  });

  final AudioEngine audio;
  final SessionRegistry registry;
  final DateTime Function() now;
  final WifiBand Function() wifiBand;

  /// Called when a different phone becomes the active one (e.g. to re-read a band that was unknown at boot).
  final void Function()? onPhoneActive;

  final _status = StreamController<ReceiverStatus>.broadcast();
  StreamSubscription<Datagram>? _sub;
  Timer? _timer, _pollTimer;
  bool _running = false, _polling = false;
  bool _gainLimiting = false; // on above 20 permille, off below 10: no flicker, no needless status changes
  int _hk = 0, _statsSent = 0;
  final loss = LossMeter();
  final _delays = <int>[];
  int? _tvDelayMs, _jitterMs, _lostPermille;
  AudioStats? _stats, _prev; // _prev: the counters at the last once-a-second delta
  Peer? _accepted, _statsPhone;
  bool _acceptOk = true; // native starts by accepting nobody; false after a failed accept so it is retried
  DateTime? _lastStatsLog;
  ReceiverStatus _last = const ReceiverStatus(TvState.listening);

  @override
  Stream<ReceiverStatus> get status => _status.stream;

  /// Latest native numbers (null before the first poll); for the log line.
  AudioStats? get stats => _stats;
  Stream<String> get socketEvents => audio.socketEvents;

  ReceiverStatus get current => ReceiverStatus(
    _state(),
    framesRx: _stats?.received ?? 0,
    framesDropped: _stats?.late ?? 0,
    underruns: _stats?.lost ?? 0,
    rttMs: registry.activePhone == null ? null : registry.phoneInfo?.rttMs,
    delayMs: registry.activePhone == null ? null : registry.phoneInfo?.delayMs,
    tvDelayMs: _tvDelayMs,
    lostPermille: _lostPermille,
    band: wifiBand(),
    gainLimiting: _gainLimiting,
  );

  Future<void> start() async {
    _running = true;
    _sub = audio.packets.listen(_onDatagram);
    _timer = Timer.periodic(_housekeeping, (_) {
      _refresh(force: true);
      if (++_hk % 10 == 0) _everySecond();
    });
    _pollTimer = Timer.periodic(_statsPoll, (_) => unawaited(_poll()));
    try {
      await audio.start(); // the native side retries the bind by itself
    } catch (e) {
      dev.log('audio start failed: $e', name: 'lanmic');
    }
  }

  Future<void> stop() async {
    _running = false;
    _timer?.cancel();
    _pollTimer?.cancel();
    unawaited(_sub?.cancel());
    _sub = null;
    try {
      await audio.stop();
    } catch (e) {
      dev.log('audio stop failed: $e', name: 'lanmic');
    }
    _refresh(force: true);
    await _status.close();
  }

  /// Every 250 ms. A slow call never overlaps the next one.
  Future<void> _poll() async {
    if (!_running || _polling) return;
    _polling = true;
    try {
      final s = await audio.stats();
      if (!_running) return;
      _stats = s;
      _gainLimiting = s.limitedPermille > 20 || (_gainLimiting && s.limitedPermille >= 10);
      if (_receiving) _jitterMs = s.jitterMs;
      _refresh();
    } catch (e) {
      // Frozen numbers must not keep the state at "receiving".
      _stats = null;
      _gainLimiting = false;
      final t = now(), last = _lastStatsLog;
      if (last == null || t.difference(last) >= const Duration(seconds: 10)) {
        _lastStatsLog = t;
        dev.log('audio stats failed: $e', name: 'lanmic');
      }
      _refresh();
    } finally {
      _polling = false;
    }
  }

  bool get _receiving {
    final age = _stats?.lastAudioAgeMs;
    return age != null && age < _audioTimeout;
  }

  /// 1 s: feed the loss window, average the TV-side delay, send STATS to the active phone.
  void _everySecond() {
    if (!_running) return;
    final t = now(), s = _stats;
    if (s != null) {
      final p = _prev;
      // A native restart resets the counters: rebaseline instead of going negative.
      if (p != null && s.played >= p.played && s.lost >= p.lost && s.discarded >= p.discarded) {
        for (var i = 0; i < s.played - p.played; i++) {
          loss.played(t, lost: false);
        }
        for (var i = 0; i < s.lost - p.lost; i++) {
          loss.played(t, lost: true);
        }
        loss.discarded(t, s.discarded - p.discarded);
      }
      _prev = s;
      if (_receiving) {
        _delays.add(s.depthMs + (s.latencyMs ?? 0));
        if (_delays.length > _delaySamples) _delays.removeAt(0);
        _tvDelayMs = (_delays.reduce((x, y) => x + y) / _delays.length).round();
      }
    }
    _lostPermille = loss.lostPermille(t);
    final phone = registry.activePhone;
    if (phone == null) return;
    final band = _statsSent++ < _bandCopies ? wifiBand() : WifiBand.unknown;
    final report = StatsReport(
      tvDelayMs: _tvDelayMs,
      lostPermille: _lostPermille,
      jitterMs: _jitterMs,
      band: band,
    );
    _send(encodePacket(Packet.stats(0, registry.pin, report)), phone);
  }

  void _onDatagram(Datagram d) {
    final p = decodePacket(d.data);
    if (p == null) return;
    final res = registry.onPacket(p, d.from);
    _syncAccept(); // before the ACK goes out: the phone sends audio only after it
    final reply = res.reply;
    if (reply != null) _send(encodePacket(reply), d.from);
    final after = registry.activePhone;
    if (after != null && after != _statsPhone) {
      _statsPhone = after; // new phone: its numbers start from scratch
      onPhoneActive?.call();
      loss.clear();
      _lostPermille = null;
      _jitterMs = null;
      _delays.clear();
      _tvDelayMs = null;
      _statsSent = 0;
    }
    _refresh();
  }

  /// A failed send (e.g. ENETUNREACH) must not escape a timer or stop the packet handling.
  void _send(Uint8List d, Peer to) {
    try {
      audio.send(d, to);
    } catch (e) {
      dev.log('send failed: $e', name: 'lanmic');
    }
  }

  /// Tells native which phone to accept whenever the active phone changes (including to null on timeout).
  void _syncAccept() {
    final active = registry.activePhone;
    if (_acceptOk && active == _accepted) return;
    _accepted = active;
    _acceptOk = true;
    unawaited(
      audio.accept(active, registry.pin).catchError((Object e) {
        dev.log('accept failed: $e', name: 'lanmic');
        if (_accepted == active) _acceptOk = false; // the next 100 ms refresh retries
      }),
    );
  }

  /// Evaluates the timeouts and emits when the state (or, with [force], any counter) changed.
  void _refresh({bool force = false}) {
    _syncAccept();
    if (registry.activePhone == null) _statsPhone = null; // a same-phone reconnect starts a new session
    final next = current, state = next.state;
    if (next == _last || (!force && state == _last.state)) return;
    _last = next;
    _status.add(next);
  }

  TvState _state() => registry.activePhone == null
      ? TvState.listening
      : _receiving
      ? TvState.receiving
      : TvState.connected;
}
