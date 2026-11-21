import 'package:lanmic_protocol/lanmic_protocol.dart';

enum TvState {
  listening('Listening'),
  connected('Phone connected'),
  receiving('Receiving audio');

  const TvState(this.label);
  final String label;
}

class ReceiverStatus {
  const ReceiverStatus(
    this.state, {
    this.framesRx = 0,
    this.framesDropped = 0,
    this.underruns = 0,
    this.rttMs,
    this.delayMs,
    this.tvDelayMs,
    this.lostPermille,
    this.band = WifiBand.unknown,
    this.gainLimiting = false,
  });

  final TvState state;
  final int framesRx, framesDropped, underruns;
  final int? rttMs, delayMs, tvDelayMs, lostPermille;

  /// The Voice-volume limiter is working (with hysteresis: on above 20 permille, off below 10). UI only.
  final bool gainLimiting;
  final WifiBand band;

  Map<String, Object?> toMap() => {
    'state': state.name,
    'framesRx': framesRx,
    'framesDropped': framesDropped,
    'underruns': underruns,
    'rttMs': rttMs,
    'delayMs': delayMs,
    'tvDelayMs': tvDelayMs,
    'lostPermille': lostPermille,
    'band': band.index,
    'gainLimiting': gainLimiting,
  };

  factory ReceiverStatus.fromMap(Map<Object?, Object?> m) => ReceiverStatus(
    TvState.values.asNameMap()[m['state']] ?? TvState.listening,
    framesRx: m['framesRx'] as int? ?? 0,
    framesDropped: m['framesDropped'] as int? ?? 0,
    underruns: m['underruns'] as int? ?? 0,
    rttMs: m['rttMs'] as int?,
    delayMs: m['delayMs'] as int?,
    tvDelayMs: m['tvDelayMs'] as int?,
    lostPermille: m['lostPermille'] as int?,
    band: switch (m['band']) {
      final int i when i >= 0 && i < WifiBand.values.length => WifiBand.values[i],
      _ => WifiBand.unknown,
    },
    gainLimiting: m['gainLimiting'] as bool? ?? false,
  );

  @override
  bool operator ==(Object other) =>
      other is ReceiverStatus &&
      other.state == state &&
      other.framesRx == framesRx &&
      other.framesDropped == framesDropped &&
      other.underruns == underruns &&
      other.rttMs == rttMs &&
      other.delayMs == delayMs &&
      other.tvDelayMs == tvDelayMs &&
      other.lostPermille == lostPermille &&
      other.band == band &&
      other.gainLimiting == gainLimiting;

  @override
  int get hashCode => Object.hash(
    state,
    framesRx,
    framesDropped,
    underruns,
    rttMs,
    delayMs,
    tvDelayMs,
    lostPermille,
    band,
    gainLimiting,
  );

  @override
  String toString() =>
      '$state rx=$framesRx dropped=$framesDropped underruns=$underruns';
}

abstract class ReceiverStatusSource {
  Stream<ReceiverStatus> get status;
}
