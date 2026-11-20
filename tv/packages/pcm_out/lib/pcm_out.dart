import 'package:flutter/services.dart';

const _frameBytes = 960; // 10 ms of 48 kHz mono PCM16

/// Plays 10 ms PCM16 mono frames through a low-latency Android AudioTrack.
class PcmOut {
  static const _channel = MethodChannel('pcm_out');
  bool _started = false;

  Future<void> start() async {
    await _channel.invokeMethod<void>('start', {
      'sampleRate': 48000,
      'channels': 1,
      'usage': 'media',
      'contentType': 'speech',
      'lowLatency': true,
    });
    _started = true;
  }

  Future<void> write(Uint8List frame) {
    if (!_started) throw StateError('PcmOut.start() has not been called');
    if (frame.length != _frameBytes) {
      throw ArgumentError.value(frame.length, 'frame', 'must be $_frameBytes bytes');
    }
    return _channel.invokeMethod<void>('write', frame);
  }

  /// Output latency (queue + AudioTrack) and cumulative drop-oldest count.
  Future<({int? latencyMs, int dropped})> stats() async {
    final m = await _channel.invokeMapMethod<String, Object?>('stats');
    return (latencyMs: m?['latencyMs'] as int?, dropped: (m?['dropped'] as int?) ?? 0);
  }

  Future<void> stop() async {
    _started = false;
    await _channel.invokeMethod<void>('stop');
  }
}
