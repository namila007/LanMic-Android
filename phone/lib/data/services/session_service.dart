import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:lanmic/domain/connection_machine.dart';
import 'package:lanmic/domain/link_stats.dart';
import 'package:lanmic/domain/phone_state.dart';
import 'package:lanmic_protocol/lanmic_protocol.dart';

typedef Incoming = ({Packet packet, InternetAddress from, int port});

/// The UDP socket the session talks through (the native receiver's socket on a real phone).
abstract class PacketPort {
  Stream<Incoming> get incoming;

  /// Fails with an error when the OS refuses the send.
  Future<void> send(Uint8List bytes, String host, int port);

  /// Closes and rebinds the socket; the source port changes.
  Future<void> rebind();

  /// A port per (re)bind.
  Stream<int> get boundPorts;
}

/// Drives a [ConnectionMachine] to one TV. HELLO/END go through the [PacketPort]; audio is sent by the
/// native capture, which this service tells where to send (`setTarget`) only while connected.
class SessionService {
  SessionService({
    required PacketPort port,
    required Future<void> Function(String? host, int port, int pin) setTarget,
    DateTime Function()? now,
    this.tvPort = kPort,
    Duration Function()? elapsed,
  }) : _port = port,
       // ignore: prefer_initializing_formals
       _setTarget = setTarget,
       _elapsed = elapsed ?? _monotonic(),
       _now = now ?? DateTime.now {
    _machine = ConnectionMachine(
      sendHello: _sendHello,
      onChange: () {
        _states.add(_machine.state);
        _syncTarget();
      },
    );
    port.incoming.listen(_onPacket);
    // A new source port while a session is active: native stops sending (its target is cleared with the
    // old socket); announce the new port with a HELLO, and the next ACK sets the target again.
    port.boundPorts.listen((_) {
      _rebindPending = false;
      if (_tv == null) return;
      _setTargetNow(null); // stay connected (a live talk goes on); audio resumes on the next ACK
      _machine.rebound(_now());
    });
  }

  final PacketPort _port;
  final Future<void> Function(String? host, int port, int pin) _setTarget;
  final DateTime Function() _now;
  final Duration Function() _elapsed;
  final _link = LinkStats();
  final _linkUpdates = StreamController<LinkSnapshot>.broadcast();
  int _pingId = 0;
  final int tvPort;
  late final ConnectionMachine _machine;
  final _states = StreamController<PhoneState>.broadcast();
  Timer? _timer;
  InternetAddress? _tv;
  int _pin = 0;
  bool _targetSet = false;
  bool _rebindPending = false; // one rebind per dead socket; cleared by the next bound port

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

  int _ticks = 0;

  void _onTick() {
    _machine.tick(_now());
    if (++_ticks % 4 != 0) return; // 4 ticks = 1 s
    final st = _machine.state;
    if (st == PhoneState.connected || st == PhoneState.lost) {
      _linkUpdates.add(link);
    }
  }

  /// The native sender sends only while connected: set the target then, clear it in every other state.
  void _syncTarget() {
    final tv = _tv;
    final on = tv != null && _machine.state == PhoneState.connected;
    _setTargetNow(on ? tv : null);
  }

  void _setTargetNow(InternetAddress? tv) {
    _targetSet = tv != null;
    _setTarget(tv?.address, tv == null ? 0 : tvPort, tv == null ? 0 : _pin).catchError((Object e) {
      debugPrint('setTarget failed: $e');
      _machine.onSendFailure();
    });
  }

  /// Measured native input latency (null = unknown) for the Delay figure.
  void setPhoneLatency(int? ms) => _link.setPhoneLatency(ms);

  /// Current HELLO round trip and total delay, for the debug log.
  HelloInfo get helloInfo => _link.helloInfo;

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

  /// A sender for END to the TV and PIN of this moment, so a quick disconnect -> connect cannot send it to
  /// the new TV. Call it only after the capture stopped, so END cannot overtake the last audio frame.
  void Function() endSender() {
    final tv = _tv, pin = _pin;
    return () => _send(Packet.end(0, pin), tv);
  }

  void _send(Packet p, [InternetAddress? to]) {
    final tv = to ?? _tv;
    if (tv == null) return;
    _port.send(encodePacket(p), tv.address, tvPort).then((_) {}, onError: (Object _) {
      _machine.onSendFailure();
      // An idle socket that the OS killed (backgrounded app, Wi-Fi switch): the audio-path monitor cannot
      // see it, so rebind once; the next bound port re-arms this.
      if (!_rebindPending) {
        _rebindPending = true;
        _port.rebind().ignore();
      }
    });
  }

  void _onPacket(Incoming i) {
    if (i.from != _tv || i.port != tvPort) return;
    switch (i.packet.type) {
      case PacketType.ack:
        _link.ackReceived(i.packet.seq, _elapsed());
        _machine.onAck(i.packet.ackName, _now());
        if (_machine.state == PhoneState.connected && !_targetSet) _syncTarget(); // back from a rebind
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
