import 'package:flutter/services.dart';

/// Snapshot of the native audio path. Null where the native value is unknown (-1).
class NativeStats {
  const NativeStats({
    required this.received,
    required this.played,
    required this.lost,
    required this.discarded,
    required this.late,
    required this.depthMs,
    required this.targetMs,
    required this.jitterMs,
    required this.lastAudioAgeMs,
    required this.latencyMs,
    required this.open,
    required this.exclusive,
    required this.mmap,
    required this.burst,
    required this.bufferFrames,
    required this.xruns,
  });

  /// Index order of the native stats array (see NativeAudio.kt).
  factory NativeStats.fromList(List<int> v) {
    int? known(int i) => v[i] < 0 ? null : v[i];
    return NativeStats(
      received: v[0],
      played: v[1],
      lost: v[2],
      discarded: v[3],
      late: v[4],
      depthMs: v[5],
      targetMs: v[6],
      jitterMs: v[7],
      lastAudioAgeMs: known(8),
      latencyMs: known(9),
      open: v[10] == 1,
      exclusive: v[11] == 1,
      mmap: v[12] < 0 ? null : v[12] == 1,
      burst: v[13],
      bufferFrames: v[14],
      xruns: v[15],
    );
  }

  final int received, played, lost, discarded, late;
  final int depthMs, targetMs, jitterMs;
  final int? lastAudioAgeMs, latencyMs;
  final bool open, exclusive;
  final bool? mmap;
  final int burst, bufferFrames, xruns;
}

/// Kotlin-owned UDP socket plus the native low-latency audio path. Only non-AUDIO packets reach Dart.
class NativeReceiver {
  static const _method = MethodChannel('pcm_out');
  static const _events = EventChannel('pcm_out/packets');

  // One platform listener shared by packets and socketEvents: the native side keeps only the last sink.
  late final Stream<Map<Object?, Object?>> _shared =
      _events.receiveBroadcastStream().cast<Map<Object?, Object?>>();

  Stream<({Uint8List data, String host, int port})> get packets => _shared
      .where((e) => e.containsKey('data'))
      .map((e) => (data: e['data'] as Uint8List, host: e['host'] as String, port: e['port'] as int));

  /// `bound: ...` / `error: ...` lines from the Kotlin socket supervisor.
  Stream<String> get socketEvents => _shared
      .where((e) => e.containsKey('event'))
      .map((e) => '${e['event']}: ${e['message']}');

  /// Ports from each `bound` event: a port-0 (ephemeral) socket gets a new one on every rebind.
  Stream<int> get boundPorts => _shared
      .where((e) => e['event'] == 'bound')
      .map((e) => int.parse((e['message'] as String).split(' ').last));

  /// [port] 0 binds an ephemeral port (the phone); the TV passes 5004.
  Future<void> start({int port = 5004}) => _method.invokeMethod<void>('start', {'port': port});

  Future<void> stop() => _method.invokeMethod<void>('stop');

  /// Closes and rebinds the socket (a new port when started with 0); a `bound` event follows.
  Future<void> rebind() => _method.invokeMethod<void>('rebind');

  /// The phone whose audio is played; all nulls accept nobody.
  Future<void> accept(String? host, int? port, int? pin) =>
      _method.invokeMethod<void>('accept', {'host': host, 'port': port, 'pin': pin});

  /// Throws [PlatformException] when the send fails.
  Future<void> send(Uint8List data, String host, int port) =>
      _method.invokeMethod<void>('send', {'data': data, 'host': host, 'port': port});

  Future<NativeStats> stats() async =>
      NativeStats.fromList((await _method.invokeListMethod<int>('stats'))!);
}

/// Snapshot of the phone capture path. Null where the native value is unknown (-1).
class CaptureStats {
  const CaptureStats({
    required this.capturing,
    required this.inputLatencyMs,
    required this.framesCaptured,
    required this.framesSent,
    required this.framesDropped,
    required this.sendErrors,
    required this.sendGapMaxMs,
    required this.levelRms,
    required this.gateOpenFrames,
    required this.gateFrames,
    required this.gateMinDb,
    required this.gateMaxDb,
    required this.mmap,
    required this.exclusive,
    required this.burst,
    required this.xruns,
  });

  /// Index order of the native capture stats array (see NativeAudio.kt).
  factory CaptureStats.fromList(List<int> v) {
    int? known(int i) => v[i] < 0 ? null : v[i];
    return CaptureStats(
      capturing: v[0] == 1,
      inputLatencyMs: known(1),
      framesCaptured: v[2],
      framesSent: v[3],
      framesDropped: v[4],
      sendErrors: v[5],
      sendGapMaxMs: known(6),
      levelRms: v[7] / 1000,
      gateOpenFrames: v[8],
      gateFrames: v[9],
      gateMinDb: v[10] / 10,
      gateMaxDb: v[11] / 10,
      mmap: v[12] < 0 ? null : v[12] == 1,
      exclusive: v[13] == 1,
      burst: v[14],
      xruns: v[15],
    );
  }

  final bool capturing;
  final int? inputLatencyMs, sendGapMaxMs;
  final int framesCaptured, framesSent, framesDropped, sendErrors;
  final double levelRms; // 0..1
  final int gateOpenFrames, gateFrames; // reset on read
  final double gateMinDb, gateMaxDb;
  final bool? mmap;
  final bool exclusive;
  final int burst, xruns;
}

/// Phone microphone capture: native Oboe input, gate and UDP sender. Audio leaves from the
/// [NativeReceiver] socket, only while capturing and a target is set.
class NativeCapture {
  static const _method = MethodChannel('pcm_out');

  /// Throws [PlatformException] with code `open_failed` or `format_unsupported`.
  Future<void> start() => _method.invokeMethod<void>('captureStart');

  /// Completes after every queued frame was sent, so END can follow safely.
  Future<void> stop() => _method.invokeMethod<void>('captureStop');

  /// A null [host] clears the target (native stops sending).
  Future<void> setTarget(String? host, int port, int pin) =>
      _method.invokeMethod<void>('setTarget', {'host': host, 'port': port, 'pin': pin});

  Future<CaptureStats> stats() async =>
      CaptureStats.fromList((await _method.invokeListMethod<int>('captureStats'))!);
}
