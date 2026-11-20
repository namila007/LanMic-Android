import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:lanmic_protocol/lanmic_protocol.dart';
import 'package:test/test.dart';

Uint8List hex(String s) => Uint8List.fromList([
      for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)
    ]);

String toHex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  test('encode then decode round-trips every type', () {
    final packets = [
      Packet.hello(1, 482917),
      Packet.ack(2, 482917, 'Chromecast'),
      Packet.audio(3, 482917, Uint8List.fromList(List.filled(kFrameBytes, 7))),
      Packet.end(4, 482917),
      Packet.reject(5, 482917),
    ];
    for (final p in packets) {
      final d = decodePacket(encodePacket(p))!;
      expect(d.type, p.type);
      expect(d.seq, p.seq);
      expect(d.pin, p.pin);
      expect(d.payload, p.payload);
    }
  });

  test('header is little-endian', () {
    expect(toHex(encodePacket(Packet.hello(1, 482917))), '544d010101000000655e0700');
  });

  test('audio packet is 972 bytes', () {
    expect(encodePacket(Packet.audio(0, 1, Uint8List(960))).length, kMaxDatagram);
  });

  group('decode rejects', () {
    final good = encodePacket(Packet.hello(1, 2));
    Uint8List patch(int i, int v) => (Uint8List.fromList(good)..[i] = v);
    final cases = <String, Uint8List>{
      'bad magic': patch(0, 0),
      'bad version': patch(2, 2),
      'unknown type': patch(3, 9),
      'short': Uint8List(11),
      'oversize': Uint8List(973),
      'audio payload 959': Uint8List.fromList(
          [...encodePacket(Packet.audio(0, 1, Uint8List(960))).sublist(0, 12), ...Uint8List(959)]),
    };
    cases.forEach((name, bytes) => test(name, () => expect(decodePacket(bytes), isNull)));
  });

  test('ack name truncates to 32 UTF-8 bytes without splitting a code point', () {
    final p = Packet.ack(0, 1, 'Ä' * 20);
    expect(p.payload.length, lessThanOrEqualTo(kAckNameMaxBytes));
    expect(decodePacket(encodePacket(p))!.ackName, 'Ä' * 16);
  });

  test('ackName is null for non-ack', () {
    expect(Packet.hello(0, 1).ackName, isNull);
  });

  test('seq and pin are u32', () {
    expect(decodePacket(encodePacket(Packet.hello(0xFFFFFFFF, 0xFFFFFFFF)))!.seq, 0xFFFFFFFF);
    expect(() => Packet.hello(-1, 1), throwsArgumentError);
    expect(() => Packet.hello(0x100000000, 1), throwsArgumentError);
    expect(() => Packet.hello(1, -1), throwsArgumentError);
  });

  test('audio frame must be 960 bytes', () {
    expect(() => Packet.audio(0, 1, Uint8List(959)), throwsArgumentError);
  });

  group('golden vectors', () {
    final vectors = jsonDecode(File('test/vectors.json').readAsStringSync()) as List;
    for (final v in vectors.cast<Map<String, dynamic>>()) {
      test(v['name'], () {
        final bytes = hex(v['hex']);
        final p = decodePacket(bytes)!;
        expect(p.type.name, v['type']);
        expect(p.seq, v['seq']);
        expect(p.pin, v['pin']);
        expect(toHex(p.payload), v['payloadHex']);
        expect(encodePacket(p), bytes);
      });
    }
  });
}
