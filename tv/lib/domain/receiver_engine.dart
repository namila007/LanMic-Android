import 'dart:async';
import 'dart:developer' as dev;
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:lanmic_protocol/lanmic_protocol.dart';

import 'jitter_buffer.dart';
import 'jitter_meter.dart';
import 'loss_meter.dart';
import 'playback_pump.dart';
import 'receiver_status.dart';
import 'session_registry.dart';

class Datagram {
  const Datagram(this.data, this.from);
  final Uint8List data;
  final Peer from;
}

abstract class DatagramPort {
  Stream<Datagram> get incoming;
  void send(Uint8List d, Peer to);
  Future<void> close();
}

abstract class PcmSink {
  Future<void> start();
  Future<void> write(Uint8List frame);
  Future<void> stop();
  Future<({int? latencyMs, int dropped})> stats();
}

const _audioTimeout = Duration(milliseconds: 500);
const _housekeeping = Duration(milliseconds: 100);
const _rebindDelay = Duration(seconds: 1);
const _maxBindDelay = 5;
const _underrunGrace = Duration(milliseconds: 100);
const _bandCopies = 3; // the band goes out in the first few STATS only; 3 copies survive UDP loss
const _delaySamples = 5;

WifiBand _unknownBand() => WifiBand.unknown;

class ReceiverEngine implements ReceiverStatusSource {
  ReceiverEngine({
    required this._bind,
    required this.registry,
    required this.buffer,
    required this.sink,
    required this.now,
    this.wifiBand = _unknownBand,
    this.onPhoneActive,
  });

  final Future<DatagramPort> Function() _bind;
  final SessionRegistry registry;
  final JitterBuffer buffer;
  final PcmSink sink;
  final DateTime Function() now;
  final WifiBand Function() wifiBand;

  /// Called when a different phone becomes the active one (e.g. to re-read a band that was unknown at boot).
  final void Function()? onPhoneActive;

  final _status = StreamController<ReceiverStatus>.broadcast();
  DatagramPort? _port;
  StreamSubscription<Datagram>? _sub;
  Timer? _timer, _pumpTimer, _rebindTimer;
  bool _running = false;
  bool _sinkReady = false, _sinkStarting = false;
  int _epoch = 0; // bumped on every flush so a start() that finishes late knows it is stale
  DateTime? _lastAudioAt;
  int _framesRx = 0, _framesDropped = 0;
  final loss = LossMeter();
  final jitter = JitterMeter();
  final _delays = <int>[];
  int? _tvDelayMs, _latencyMs;
  int _nativeDropped = 0, _hk = 0, _statsSent = 0;
  int? _lostPermille; // refreshed once a second; keeps the loss-window loop off the datagram path
  bool _statsInFlight = false;
  Peer? _statsPhone;
  ReceiverStatus _last = const ReceiverStatus(TvState.listening);

  @override
  Stream<ReceiverStatus> get status => _status.stream;
  ReceiverStatus get current => ReceiverStatus(
    _state(),
    framesRx: _framesRx,
    framesDropped: _framesDropped,
    underruns: buffer.underruns,
    rttMs: registry.activePhone == null ? null : registry.phoneInfo?.rttMs,
    delayMs: registry.activePhone == null ? null : registry.phoneInfo?.delayMs,
    tvDelayMs: _tvDelayMs,
    lostPermille: _lostPermille,
    band: wifiBand(),
  );

  Future<void> start() async {
    _running = true;
    _timer = Timer.periodic(_housekeeping, (_) {
      _refresh(force: true);
      if (++_hk % 10 == 0) unawaited(_everySecond());
    });
    final pump = PlaybackPump(elapsed: _elapsedSince(now()), onFrame: tick);
    _pumpTimer = Timer.periodic(
      const Duration(milliseconds: 10),
      (_) => pump.tick(),
    );
    unawaited(_connect());
  }

  Duration Function() _elapsedSince(DateTime t0) =>
      () => now().difference(t0);

  Future<void> stop() async {
    _running = false;
    _timer?.cancel();
    _pumpTimer?.cancel();
    _rebindTimer?.cancel();
    unawaited(_sub?.cancel());
    await _port?.close();
    _sub = _port = null;
    _flush();
    _refresh(force: true);
    await _status.close();
  }

  /// Pop one 10 ms frame towards the sink. Nothing is popped until the sink has
  /// finished starting, so early frames wait in the jitter buffer instead of being lost.
  void tick() {
    if (!_sinkReady) {
      _startSink();
      return;
    }
    final f = buffer.pop();
    if (f == null) return;
    _guard('write', () => sink.write(f));
    final t = now();
    switch (buffer.lastPop) {
      case PopKind.voice:
        loss.played(t, lost: false);
      case PopKind.gap:
        loss.played(t, lost: true);
      case PopKind.underrun:
        // After the burst ends the buffer runs dry by design; only a dry buffer mid-burst is loss.
        final at = _lastAudioAt;
        if (at != null && t.difference(at) < _underrunGrace) {
          loss.played(t, lost: true);
        }
      case null:
    }
  }

  /// 1 s: refresh the native numbers, average the TV-side delay, send STATS to the active phone.
  Future<void> _everySecond() async {
    if (!_running) return;
    if (_sinkReady && !_statsInFlight) {
      _statsInFlight = true;
      final epoch = _epoch;
      try {
        final st = await sink.stats();
        if (epoch == _epoch) {
          // else the sink was flushed meanwhile and these numbers belong to the old session
          _latencyMs = st.latencyMs;
          loss.discarded(
            now(),
            st.dropped >= _nativeDropped ? st.dropped - _nativeDropped : st.dropped,
          );
          _nativeDropped = st.dropped;
        }
      } catch (e) {
        dev.log('sink stats failed: $e', name: 'lanmic');
      } finally {
        _statsInFlight = false;
      }
    }
    if (_sinkReady && _state() == TvState.receiving) {
      _delays.add(buffer.depth * 10 + (_latencyMs ?? 0));
      if (_delays.length > _delaySamples) _delays.removeAt(0);
      _tvDelayMs = (_delays.reduce((x, y) => x + y) / _delays.length).round();
    }
    final t = now();
    _lostPermille = loss.lostPermille(t);
    final phone = registry.activePhone;
    if (phone == null) return;
    final band = _statsSent++ < _bandCopies ? wifiBand() : WifiBand.unknown;
    final report = StatsReport(
      tvDelayMs: _tvDelayMs,
      lostPermille: _lostPermille,
      jitterMs: jitter.jitterMs,
      band: band,
    );
    try {
      _port?.send(encodePacket(Packet.stats(0, registry.pin, report)), phone);
    } on SocketException catch (e) {
      dev.log('stats send failed: $e', name: 'lanmic');
    }
  }

  void _startSink() {
    final hasAudio = buffer.isPlaying || buffer.depth >= buffer.prebuffer;
    if (_sinkStarting || !hasAudio) return;
    _sinkStarting = true;
    final epoch = _epoch;
    _guard('start', sink.start).then((ok) {
      _sinkStarting = false;
      if (!ok) return; // retried on the next tick
      if (epoch == _epoch) {
        _sinkReady = true;
      } else {
        _guard('stop', sink.stop); // flushed while starting
      }
    });
  }

  /// Runs a sink call; errors are logged, never thrown (this runs in timer callbacks).
  Future<bool> _guard(String what, Future<void> Function() call) async {
    try {
      await call();
      return true;
    } catch (e) {
      dev.log('sink $what failed: $e', name: 'lanmic');
      return false;
    }
  }

  // Bind supervisor: Wi-Fi may not be up at boot, and the socket can die later.
  Future<void> _connect() async {
    var delay = 1;
    while (_running) {
      try {
        final port = await _bind();
        if (!_running) return unawaited(port.close());
        _port = port;
        _sub = port.incoming.listen(
          _onDatagram,
          // dart:io reports a failed reply send here, then closes the socket (onDone rebinds).
          onError: (Object e) => dev.log('socket error: $e', name: 'lanmic'),
          onDone: () {
            _port = null;
            if (_running) _rebindTimer = Timer(_rebindDelay, _connect);
          },
        );
        return;
      } catch (e) {
        dev.log('bind failed: $e', name: 'lanmic'); // e.g. no Wi-Fi yet at boot
        await Future<void>.delayed(Duration(seconds: delay));
        delay = min(delay * 2, _maxBindDelay);
      }
    }
  }

  void _onDatagram(Datagram d) {
    final p = decodePacket(d.data);
    if (p == null) return;
    final before = registry.activePhone;
    final res = registry.onPacket(p, d.from);
    final reply = res.reply;
    if (reply != null) {
      try {
        _port?.send(encodePacket(reply), d.from);
      } on SocketException catch (e) {
        dev.log(
          'send failed: $e',
          name: 'lanmic',
        ); // e.g. ENETUNREACH: keep handling the packet
      }
    }
    final after = registry.activePhone;
    if (after != null && after != _statsPhone) {
      _statsPhone = after; // new phone: its numbers start from scratch
      onPhoneActive?.call();
      loss.clear();
      _lostPermille = null;
      jitter.clear();
      _delays.clear();
      _tvDelayMs = null;
      _statsSent = 0;
    }
    if (after != null && before != null && after != before) {
      _flush(); // new phone takes over
    }
    if (res.end) _flush();
    if (res.audio) {
      final t = now();
      jitter.onAudio(p.seq, t);
      final discardedBefore = buffer.discarded;
      final pushed = buffer.push(p.seq, p.payload);
      loss.discarded(t, buffer.discarded - discardedBefore);
      if (pushed) {
        _framesRx++;
        _lastAudioAt = t;
      } else {
        _framesDropped++;
      }
    }
    _refresh();
  }

  void _flush() {
    buffer.flush();
    jitter.restart();
    _latencyMs = null;
    _lastAudioAt = null;
    _epoch++;
    if (_sinkReady) {
      _sinkReady = false;
      unawaited(_guard('stop', sink.stop));
    }
  }

  /// Evaluates the timeouts and emits when the state (or, with [force], any counter) changed.
  void _refresh({bool force = false}) {
    final lastAudio = _lastAudioAt;
    if (lastAudio != null && now().difference(lastAudio) >= _audioTimeout) {
      _flush();
    }
    if (_state() == TvState.listening && _sinkReady) _flush();
    if (registry.activePhone == null) _statsPhone = null; // a same-phone reconnect starts a new session
    final next = current, state = next.state;
    if (next == _last || (!force && state == _last.state)) return;
    _last = next;
    _status.add(next);
  }

  TvState _state() => registry.activePhone == null
      ? TvState.listening
      : _lastAudioAt == null
      ? TvState.connected
      : TvState.receiving;
}
