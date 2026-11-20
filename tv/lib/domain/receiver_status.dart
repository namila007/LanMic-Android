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
  });

  final TvState state;
  final int framesRx, framesDropped, underruns;

  Map<String, Object> toMap() => {
    'state': state.name,
    'framesRx': framesRx,
    'framesDropped': framesDropped,
    'underruns': underruns,
  };

  factory ReceiverStatus.fromMap(Map<Object?, Object?> m) => ReceiverStatus(
    TvState.values.asNameMap()[m['state']] ?? TvState.listening,
    framesRx: m['framesRx'] as int? ?? 0,
    framesDropped: m['framesDropped'] as int? ?? 0,
    underruns: m['underruns'] as int? ?? 0,
  );

  @override
  bool operator ==(Object other) =>
      other is ReceiverStatus &&
      other.state == state &&
      other.framesRx == framesRx &&
      other.framesDropped == framesDropped &&
      other.underruns == underruns;

  @override
  int get hashCode => Object.hash(state, framesRx, framesDropped, underruns);

  @override
  String toString() =>
      '$state rx=$framesRx dropped=$framesDropped underruns=$underruns';
}

abstract class ReceiverStatusSource {
  Stream<ReceiverStatus> get status;
}
