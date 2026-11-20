import 'dart:io';
import 'dart:typed_data';

import 'package:lanmic_protocol/lanmic_protocol.dart';

import '../../domain/receiver_engine.dart';
import '../../domain/session_registry.dart';

class UdpSocketService implements DatagramPort {
  UdpSocketService._(this._socket);

  final RawDatagramSocket _socket;

  static Future<UdpSocketService> bind({int port = kPort}) async =>
      UdpSocketService._(
        await RawDatagramSocket.bind(InternetAddress.anyIPv4, port),
      );

  int get port => _socket.port;

  @override
  Stream<Datagram> get incoming =>
      _socket.where((e) => e == RawSocketEvent.read).expand((_) sync* {
        for (var d = _socket.receive(); d != null; d = _socket.receive()) {
          yield Datagram(d.data, Peer(d.address.address, d.port));
        }
      });

  @override
  void send(Uint8List d, Peer to) =>
      _socket.send(d, InternetAddress(to.host), to.port);

  @override
  Future<void> close() async => _socket.close();
}
