const _frameMs = 10;

/// Turns jittery timer ticks into a steady 10 ms frame clock: emits the frames
/// that are due, at most [maxBurst] per tick, then resyncs so a stall leaves no backlog.
class PlaybackPump {
  PlaybackPump({
    required this.elapsed,
    required this.onFrame,
    this.maxBurst = 3,
  }) : _base = elapsed();

  final Duration Function() elapsed;
  final void Function() onFrame;
  final int maxBurst;
  final Duration _base;
  int _emitted = 0;

  void tick() {
    final due = (elapsed() - _base).inMilliseconds ~/ _frameMs;
    final n = due - _emitted;
    // Wall clock stepped back (e.g. NTP after boot): resync, don't go silent.
    if (n < 0) _emitted = due;
    for (var i = 0; i < n && i < maxBurst; i++) {
      onFrame();
    }
    if (n > 0) _emitted = n > maxBurst ? due : _emitted + n;
  }
}
