import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanmic_protocol/lanmic_protocol.dart';
import 'package:lanmic_tv/domain/jitter_buffer.dart';
import 'package:lanmic_tv/domain/receiver_engine.dart';
import 'package:lanmic_tv/domain/receiver_status.dart';
import 'package:lanmic_tv/domain/session_registry.dart';

const pin = 482917;
const a = Peer('10.0.0.1', 4000);
const b = Peer('10.0.0.2', 4001);

class FakePort implements DatagramPort {
  final ctl = StreamController<Datagram>(sync: true);
  final sent = <(Uint8List, Peer)>[];
  bool closed = false, failSend = false;
  @override
  Stream<Datagram> get incoming => ctl.stream;
  @override
  void send(Uint8List d, Peer to) {
    if (failSend) throw const SocketException('Network is unreachable');
    sent.add((d, to));
  }

  @override
  Future<void> close() async => closed = true;
}

/// Mirrors the real PcmOut: start completes asynchronously, and write throws
/// synchronously until start has completed.
class FakeSink implements PcmSink {
  FakeSink({
    this.failStarts = 0,
    this.failWrites = false,
    this.failStop = false,
  });
  final int failStarts;
  final bool failWrites, failStop;
  int? latencyMs;
  int dropped = 0;
  int starts = 0, stops = 0;
  bool started = false;
  final writes = <Uint8List>[];
  @override
  Future<void> start() async {
    final n = ++starts;
    await Future<void>.value();
    if (n <= failStarts) throw StateError('start failed');
    started = true;
  }

  @override
  Future<void> write(Uint8List frame) {
    if (!started) throw StateError('write before start completed');
    if (failWrites) return Future.error(StateError('write failed'));
    writes.add(frame);
    return Future.value();
  }

  @override
  Future<({int? latencyMs, int dropped})> stats() async =>
      (latencyMs: latencyMs, dropped: dropped);

  @override
  Future<void> stop() async {
    stops++;
    started = false;
    if (failStop) throw StateError('stop failed');
  }
}

class Rig {
  Rig(
    this.async, {
    Future<DatagramPort> Function()? bind,
    FakeSink? sink,
    WifiBand band = WifiBand.ghz5,
    void Function()? onPhoneActive,
  })
    : sink = sink ?? FakeSink() {
    engine = ReceiverEngine(
      bind: bind ?? () async => port,
      registry: SessionRegistry(pin: pin, name: 'Chromecast', now: now),
      buffer: buffer,
      sink: this.sink,
      now: now,
      wifiBand: () => band,
      onPhoneActive: onPhoneActive,
    );
    engine.start();
    async.flushMicrotasks();
  }
  final FakeAsync async;
  final port = FakePort();
  final FakeSink sink;
  final buffer = JitterBuffer();
  late final ReceiverEngine engine;
  DateTime now() => DateTime(2026).add(async.elapsed);

  void rx(Packet p, [Peer from = a]) {
    port.ctl.add(Datagram(encodePacket(p), from));
    async.flushMicrotasks();
  }

  void hello([Peer from = a, HelloInfo? info]) =>
      rx(Packet.hello(1, pin, info), from);
  void audio(int seq, [Peer from = a]) => rx(
    Packet.audio(seq, pin, Uint8List(kFrameBytes)..[0] = seq & 0xFF),
    from,
  );
  void ticks(int n) {
    for (var i = 0; i < n; i++) {
      engine.tick();
    }
  }

  TvState get state => engine.current.state;
}

void rig(String name, void Function(Rig r) body) =>
    test(name, () => fakeAsync((async) => body(Rig(async))));

