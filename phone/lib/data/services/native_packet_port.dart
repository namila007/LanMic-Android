import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:lanmic/data/services/session_service.dart';
import 'package:lanmic_protocol/lanmic_protocol.dart';
import 'package:pcm_out/pcm_out.dart';

/// [PacketPort] over the native receiver's socket (bound to an ephemeral port, shared with the audio sender).
class NativePacketPort implements PacketPort {
  NativePacketPort(this._r);

  final NativeReceiver _r;

  @override
  Stream<Incoming> get incoming => _r.packets
      .map((e) => (p: decodePacket(e.data), from: InternetAddress.tryParse(e.host), port: e.port))
      .where((e) => e.p != null && e.from != null)
      .map((e) => (packet: e.p!, from: e.from!, port: e.port));

  @override
  Future<void> send(Uint8List bytes, String host, int port) => _r.send(bytes, host, port);

  @override
  Future<void> rebind() => _r.rebind();

  @override
  Stream<int> get boundPorts => _r.boundPorts;
}
