import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:lanmic/data/services/udp_sender.dart';
import 'package:lanmic/domain/connection_machine.dart';
import 'package:lanmic/domain/link_stats.dart';
import 'package:lanmic/domain/phone_state.dart';
import 'package:lanmic_protocol/lanmic_protocol.dart';

/// Drives a [ConnectionMachine] over a real socket to one TV.
class SessionService {
  SessionService({
    required UdpSender sender,
    DateTime Function()? now,
    this.port = kPort,
    int initialSeq = 0,
    Duration Function()? elapsed,
  }) : _sender = sender,
       _elapsed = elapsed ?? _monotonic(),
       _now = now ?? DateTime.now,
       _seq = initialSeq {
    _machine = ConnectionMachine(
      sendHello: _sendHello,
      onChange: () => _states.add(_machine.state),
    );
    sender.incoming.listen(_onPacket);
  }

  final UdpSender _sender;
  final DateTime Function() _now;
  final Duration Function() _elapsed;
  final _link = LinkStats();
  final _linkUpdates = StreamController<LinkSnapshot>.broadcast();
  int _pingId = 0;
  final int port;
  late final ConnectionMachine _machine;
  final _states = StreamController<PhoneState>.broadcast();
  Timer? _timer;
  InternetAddress? _tv;
  int _pin = 0;
  int _seq;
  bool _talking = false;
  int _sent = 0; // audio packets since the last log line
  int _ticks = 0;

  Stream<PhoneState> get states => _states.stream;
  PhoneState get state => _machine.state;
  String? get tvName => _machine.tvName;
  LinkSnapshot get link => _link.snapshot(_elapsed());
  Stream<LinkSnapshot> get linkUpdates => _linkUpdates.stream;

  Future<void> connect(InternetAddress tv, int pin) async {
    _tv = tv;
    _pin = pin;
    _timer?.cancel();
    _timer = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => _onTick(),
    );
    _link.reset(_elapsed());
    _machine.connect(_now());
  }

  void _onTick() {
    _machine.tick(_now());
    if (++_ticks % 4 != 0) return; // 4 ticks = 1 s
    final st = _machine.state;
    if (st == PhoneState.connected || st == PhoneState.lost) {
      _linkUpdates.add(link);
    }
    if (_sent == 0) return;
    // Seq-gap check: compare nextSeq deltas with the TV log.
    final l = _link.helloInfo;
    debugPrint('audio sent=$_sent nextSeq=$_seq rtt=${l.rttMs} delay=${l.delayMs}');
    _sent = 0;
  }

  void _sendHello() {
    _pingId = (_pingId + 1) & 0xFFFFFFFF;
    _link.helloSent(_pingId, _elapsed());
    _send(Packet.hello(_pingId, _pin, _link.helloInfo));
  }

  Future<void> disconnect() async {
    _timer?.cancel();
    _timer = null;
    _machine.disconnect();
  }

  /// A burst starts here and ends at [sendEnd]; audio outside a burst is dropped.
  void beginTalk() => _talking = true;

  void sendAudio(Uint8List frame960) {
    if (!_talking || _machine.state != PhoneState.connected) return;
    _send(Packet.audio(_seq, _pin, frame960));
    _sent++;
    _seq = (_seq + 1) & 0xFFFFFFFF;
  }

  void sendEnd() {
    _talking = false;
    _send(Packet.end(0, _pin));
  }

  void _send(Packet p) {
    final tv = _tv;
    if (tv == null) return;
    try {
      _sender.send(encodePacket(p), tv, port);
    } on SocketException {
      _machine.onSendFailure();
    }
  }

  void _onPacket(Incoming i) {
    if (i.from != _tv || i.port != port) return;
    switch (i.packet.type) {
      case PacketType.ack:
        _link.ackReceived(i.packet.seq, _elapsed());
        _machine.onAck(i.packet.ackName, _now());
      case PacketType.reject:
        _machine.onReject();
      case PacketType.stats:
        final r = i.packet.statsReport;
        if (r != null && i.packet.pin == _pin) _link.statsReceived(r);
      default:
    }
  }
}

Duration Function() _monotonic() {
  final w = Stopwatch()..start();
  return () => w.elapsed;
}
