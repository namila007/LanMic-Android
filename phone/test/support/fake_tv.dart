import 'dart:io';

import 'package:lanmic_protocol/lanmic_protocol.dart';

/// Loopback stand-in for the TV: ACKs/REJECTs HELLOs, records everything.
class FakeTv {
  FakeTv._(this._socket, this.pin, this.name, this.answer);

  static Future<FakeTv> start({
    required int pin,
    String name = 'Living Room',
    bool answer = true,
  }) async {
    final s = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    final tv = FakeTv._(s, pin, name, answer);
    s.listen(tv._onEvent);
    return tv;
  }

  final RawDatagramSocket _socket;
  final int pin;
  final String name;
  bool answer;
  final received = <Packet>[];

  int get port => _socket.port;

  void _onEvent(RawSocketEvent e) {
    if (e != RawSocketEvent.read) return;
    final d = _socket.receive();
    if (d == null) return;
    final p = decodePacket(d.data);
    if (p == null) return;
    received.add(p);
    if (p.type != PacketType.hello || !answer) return;
    sendTo(
      p.pin == pin ? Packet.ack(0, p.pin, name) : Packet.reject(0, p.pin),
      d.address,
      d.port,
    );
  }

  void sendTo(Packet p, InternetAddress to, int port) =>
      _socket.send(encodePacket(p), to, port);

  int count(PacketType t) => received.where((p) => p.type == t).length;

  void close() => _socket.close();
}
