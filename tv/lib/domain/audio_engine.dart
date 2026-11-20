import 'dart:typed_data';

import 'session_registry.dart';

class Datagram {
  const Datagram(this.data, this.from);
  final Uint8List data;
  final Peer from;
}

/// Snapshot of the native audio path (same fields as the plugin's NativeStats).
class AudioStats {
  const AudioStats({
    this.received = 0,
    this.played = 0,
    this.lost = 0,
    this.discarded = 0,
    this.late = 0,
    this.depthMs = 0,
    this.targetMs = 0,
    this.jitterMs = 0,
    this.lastAudioAgeMs,
    this.latencyMs,
    this.open = false,
    this.exclusive = false,
    this.mmap,
    this.burst = 0,
    this.bufferFrames = 0,
    this.xruns = 0,
  });

  final int received, played, lost, discarded, late;
  final int depthMs, targetMs, jitterMs;
  final int? lastAudioAgeMs, latencyMs;
  final bool open, exclusive;
  final bool? mmap;
  final int burst, bufferFrames, xruns;
}

/// The socket and the audio output. AUDIO never reaches Dart: the engine only sees control packets.
abstract class AudioEngine {
  Stream<Datagram> get packets;

  /// Socket lines such as `bound: port 5004` or `error: bind failed`, for the log.
  Stream<String> get socketEvents;
  Future<void> start();
  Future<void> stop();

  /// The phone whose audio is played; null accepts nobody.
  Future<void> accept(Peer? peer, int pin);
  void send(Uint8List d, Peer to);
  Future<AudioStats> stats();
}
