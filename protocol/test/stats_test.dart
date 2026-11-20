import 'dart:typed_data';

import 'package:lanmic_protocol/lanmic_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('HELLO info', () {
    test('hello without info has an empty payload and null info', () {
      final p = Packet.hello(1, 2);
      expect(p.payload, isEmpty);
      expect(p.helloInfo, isNull);
    });

    test('hello info round-trips in 4 bytes', () {
      final p = decodePacket(
        encodePacket(Packet.hello(7, 2, (rttMs: 9, delayMs: 140))),
      )!;
      expect(p.payload.length, kHelloInfoBytes);
      expect(p.helloInfo, (rttMs: 9, delayMs: 140));
    });

    test('null fields travel as 0xFFFF and decode to null', () {
      final p = Packet.hello(1, 2, (rttMs: null, delayMs: 140));
      expect(p.payload.sublist(0, 2), [0xFF, 0xFF]);
      expect(
        decodePacket(encodePacket(p))!.helloInfo,
        (rttMs: null, delayMs: 140),
      );
    });

    test('out-of-range values clamp instead of becoming unknown', () {
      final p = decodePacket(
        encodePacket(Packet.hello(1, 2, (rttMs: 70000, delayMs: -5))),
      )!;
      expect(p.helloInfo, (rttMs: 0xFFFE, delayMs: 0));
    });

    test('hello with a short payload still decodes, info is null', () {
      final bytes = Uint8List.fromList([
        ...encodePacket(Packet.hello(1, 2)),
        1,
        2,
      ]);
      final p = decodePacket(bytes)!;
      expect(p.type, PacketType.hello);
      expect(p.helloInfo, isNull);
    });

    test('helloInfo is null for non-hello packets', () {
      expect(Packet.end(0, 1).helloInfo, isNull);
    });
  });

  group('STATS', () {
    const r = StatsReport(
      tvDelayMs: 115,
      lostPermille: 3,
      jitterMs: 3,
      band: WifiBand.ghz2_4,
    );

    test('wire type is 5 and payload is 7 bytes', () {
      final b = encodePacket(Packet.stats(0, 2, r));
      expect(b[3], 5);
      expect(b.length, kHeaderBytes + kStatsBytes);
    });

    test('round-trips', () {
      expect(decodePacket(encodePacket(Packet.stats(0, 2, r)))!.statsReport, r);
    });

    test('unknown fields round-trip as null / unknown band', () {
      const u = StatsReport();
      expect(u.band, WifiBand.unknown);
      expect(decodePacket(encodePacket(Packet.stats(0, 2, u)))!.statsReport, u);
    });

    test('a short STATS payload is rejected', () {
      final b = encodePacket(Packet.stats(0, 2, r));
      expect(decodePacket(Uint8List.sublistView(b, 0, b.length - 1)), isNull);
    });

    test('a longer STATS payload is accepted, extra bytes ignored', () {
      final b = Uint8List.fromList([...encodePacket(Packet.stats(0, 2, r)), 9, 9]);
      expect(decodePacket(b)!.statsReport, r);
    });

    test('an unknown band byte decodes as unknown', () {
      final b = encodePacket(Packet.stats(0, 2, r))..[kHeaderBytes + 6] = 9;
      expect(decodePacket(b)!.statsReport!.band, WifiBand.unknown);
    });

    test('statsReport is null for non-stats packets', () {
      expect(Packet.hello(0, 1).statsReport, isNull);
    });
  });
}
