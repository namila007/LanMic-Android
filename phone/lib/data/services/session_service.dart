import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:lanmic/data/services/udp_sender.dart';
import 'package:lanmic/domain/connection_machine.dart';
import 'package:lanmic/domain/phone_state.dart';
import 'package:lanmic_protocol/lanmic_protocol.dart';

/// Drives a [ConnectionMachine] over a real socket to one TV.
class SessionService {
  SessionService({
    required UdpSender sender,
    DateTime Function()? now,
    this.port = kPort,
    int initialSeq = 0,
  }) : _sender = sender,
       _now = now ?? DateTime.now,
       _seq = initialSeq {
    _machine = ConnectionMachine(
      sendHello: () => _send(Packet.hello(0, _pin)),
      onChange: () => _states.add(_machine.state),
    );
    sender.incoming.listen(_onPacket);
  }

  final UdpSender _sender;
  final DateTime Function() _now;
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

  Future<void> connect(InternetAddress tv, int pin) async {
    _tv = tv;
    _pin = pin;
    _timer?.cancel();
    _timer = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => _onTick(),
    );
    _machine.connect(_now());
  }

  void _onTick() {
    _machine.tick(_now());
    if (++_ticks % 4 != 0 || _sent == 0) return; // 4 ticks = 1 s
    // Seq-gap check: compare nextSeq deltas with the TV log.
    debugPrint('audio sent=$_sent nextSeq=$_seq');
    _sent = 0;
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
        _machine.onAck(i.packet.ackName, _now());
      case PacketType.reject:
        _machine.onReject();
      default:
    }
  }
}
