import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanmic_protocol/lanmic_protocol.dart';
import 'package:lanmic_tv/data/services/udp_socket_service.dart';
import 'package:lanmic_tv/domain/receiver_engine.dart';

void main() {
  test(
    'loopback: receives, replies and carries a full-size datagram',
    () async {
      final svc = await UdpSocketService.bind(port: 0);
      addTearDown(svc.close);
      final client = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(client.close);
      final got = <Datagram>[];
      svc.incoming.listen(got.add);

      final target = InternetAddress.loopbackIPv4;
      client.send(encodePacket(Packet.hello(1, 482917)), target, svc.port);
      client.send(
        encodePacket(Packet.audio(2, 482917, Uint8List(kFrameBytes))),
        target,
        svc.port,
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(got, hasLength(2));
      expect(got.first.from.port, client.port);
      expect(got.last.data.length, kMaxDatagram);

      final reply = Completer<Uint8List>();
      client.listen((e) {
        if (e != RawSocketEvent.read) return;
        final d = client.receive();
        if (d != null) reply.complete(d.data);
      });
      svc.send(encodePacket(Packet.ack(1, 482917, 'tv')), got.first.from);
      expect(decodePacket(await reply.future)!.type, PacketType.ack);
    },
  );
}
