import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:lanmic/data/services/session_service.dart';
import 'package:lanmic_protocol/lanmic_protocol.dart';

final tvAddress = InternetAddress('192.168.1.5');

/// A [PacketPort] with a stand-in TV behind it: ACKs/REJECTs HELLOs (when [answer]), records everything sent.
class FakeTv implements PacketPort {
  FakeTv({this.pin = 482917, this.name = 'Living Room', this.answer = true});

  final int pin;
  final String name;
  bool answer;
  bool failSends = false;
  int rebinds = 0;
  final sent = <Packet>[];
  final _in = StreamController<Incoming>.broadcast(sync: true);
  final _bound = StreamController<int>.broadcast(sync: true);

  @override
  Stream<Incoming> get incoming => _in.stream;
  @override
  Stream<int> get boundPorts => _bound.stream;
  @override
  Future<void> rebind() async => rebinds++;

  @override
  Future<void> send(Uint8List bytes, String host, int port) async {
    if (failSends) throw StateError('send failed');
    final p = decodePacket(bytes)!;
    sent.add(p);
    if (p.type != PacketType.hello || !answer) return;
    receive(p.pin == pin ? Packet.ack(p.seq, p.pin, name) : Packet.reject(0, p.pin));
  }

  void receive(Packet p, {int port = kPort, InternetAddress? from}) =>
      _in.add((packet: p, from: from ?? tvAddress, port: port));

  /// The native receiver bound a new socket.
  void bound(int port) => _bound.add(port);

  int count(PacketType t) => sent.where((p) => p.type == t).length;
}
