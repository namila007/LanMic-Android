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

  Future<void> start({int port = 5004}) => _method.invokeMethod<void>('start', {'port': port});

  Future<void> stop() => _method.invokeMethod<void>('stop');

  /// The phone whose audio is played; all nulls accept nobody.
  Future<void> accept(String? host, int? port, int? pin) =>
      _method.invokeMethod<void>('accept', {'host': host, 'port': port, 'pin': pin});

  /// Throws [PlatformException] when the send fails.
  Future<void> send(Uint8List data, String host, int port) =>
      _method.invokeMethod<void>('send', {'data': data, 'host': host, 'port': port});

  Future<NativeStats> stats() async =>
      NativeStats.fromList((await _method.invokeListMethod<int>('stats'))!);
}
