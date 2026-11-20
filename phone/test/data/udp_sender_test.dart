import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanmic/data/services/udp_sender.dart';

void main() {
  test('keeps sending after the OS fails a send and closes the socket', () async {
    final rx = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    final got = Completer<void>();
    rx.listen((e) {
      if (e == RawSocketEvent.read &&
          rx.receive() != null &&
          !got.isCompleted) {
        got.complete();
      }
    });
    final sender = await UdpSender.bind();
    addTearDown(() async {
      await sender.close();
      rx.close();
    });

    // Broadcast without SO_BROADCAST fails in the OS, like Android's EPERM
    // for a backgrounded app; dart:io then reports it async and closes the socket.
    sender.send(Uint8List(4), InternetAddress('255.255.255.255'), rx.port);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    // Retry like the heartbeat does: the first sends may land while rebinding.
    for (var i = 0; i < 20 && !got.isCompleted; i++) {
      try {
        sender.send(Uint8List(4), InternetAddress.loopbackIPv4, rx.port);
      } on SocketException {
        // rebinding
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    await got.future.timeout(const Duration(seconds: 2));
  });
}
