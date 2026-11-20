// Usage: dart run tool/send_sine.dart <tvIp> <pin> [--seconds 10]
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:lanmic_protocol/lanmic_protocol.dart';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('usage: send_sine.dart <tvIp> <pin> [--seconds 10]');
    exit(64);
  }
  final tv = InternetAddress(args[0]);
  final pin = int.parse(args[1]);
  final i = args.indexOf('--seconds');
  final seconds = i >= 0 ? int.parse(args[i + 1]) : 10;

  final sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  final replies = StreamIterator(sock.where((e) => e == RawSocketEvent.read));
  sock.send(encodePacket(Packet.hello(0, pin)), tv, kPort);

  final reply = await _reply(sock, replies);
  if (reply == null) {
    stderr.writeln('no reply within 3 s');
    exit(1);
  }
  stdout.writeln(reply.type == PacketType.ack ? 'ACK from ${reply.ackName}' : reply.type.name.toUpperCase());
  if (reply.type != PacketType.ack) exit(2);

  final sw = Stopwatch()..start();
  var seq = 1, n = 0;
  while (sw.elapsedMilliseconds < seconds * 1000) {
    final frame = Int16List(kSamplesPerFrame);
    for (var k = 0; k < kSamplesPerFrame; k++, n++) {
      frame[k] = (sin(2 * pi * 440 * n / kSampleRate) * 12000).round();
    }
    sock.send(encodePacket(Packet.audio(seq, pin, frame.buffer.asUint8List())), tv, kPort);
    seq++;
    // Clock-paced, not sleep-paced, so late wakeups do not drift the rate.
    final wait = seq * 10 - sw.elapsedMilliseconds;
    if (wait > 0) await Future<void>.delayed(Duration(milliseconds: wait));
  }
  for (var k = 0; k < 2; k++) {
    sock.send(encodePacket(Packet.end(seq, pin)), tv, kPort);
  }
  stdout.writeln('sent ${seq - 1} frames');
  exit(0);
}

Future<Packet?> _reply(RawDatagramSocket sock, StreamIterator<RawSocketEvent> it) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (DateTime.now().isBefore(deadline)) {
    final left = deadline.difference(DateTime.now());
    if (!await it.moveNext().timeout(left, onTimeout: () => false)) return null;
    final d = sock.receive();
    final p = d == null ? null : decodePacket(d.data);
    if (p != null) return p;
  }
  return null;
}
