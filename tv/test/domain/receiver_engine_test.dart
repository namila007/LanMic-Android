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
  Future<void> stop() async {
    stops++;
    started = false;
    if (failStop) throw StateError('stop failed');
  }
}

class Rig {
  Rig(this.async, {Future<DatagramPort> Function()? bind, FakeSink? sink})
    : sink = sink ?? FakeSink() {
    engine = ReceiverEngine(
      bind: bind ?? () async => port,
      registry: SessionRegistry(pin: pin, name: 'Chromecast', now: now),
      buffer: buffer,
      sink: this.sink,
      now: now,
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

  void hello([Peer from = a]) => rx(Packet.hello(1, pin), from);
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

void main() {
  rig('HELLO -> ACK to sender, connected; AUDIO -> receiving', (r) {
    r.hello();
    final (bytes, to) = r.port.sent.single;
    expect(to, a);
    final ack = decodePacket(bytes)!;
    expect((ack.type, ack.ackName), (PacketType.ack, 'Chromecast'));
    expect(r.state, TvState.connected);
    r.audio(1);
    expect(r.state, TvState.receiving);
    expect(r.engine.current.framesRx, 1);
  });

  rig('plays one frame per 10 ms into the sink', (r) {
    r.hello();
    for (var i = 1; i <= 3; i++) {
      r.audio(i);
    }
    r.async.elapse(const Duration(milliseconds: 40));
    expect(r.sink.starts, 1);
    // The first frames wait in the buffer until start() completes: none are lost or thrown.
    expect(r.sink.writes.map((f) => f[0]), [1, 2, 3]);
  });

  test(
    'a failing sink.start is retried on the next frame, frames are kept',
    () {
      fakeAsync((async) {
        final r = Rig(async, sink: FakeSink(failStarts: 1));
        r.hello();
        for (var i = 1; i <= 3; i++) {
          r.audio(i);
        }
        r.async.elapse(const Duration(milliseconds: 50));
        expect(r.sink.starts, 2);
        expect(r.sink.writes.map((f) => f[0]).take(3), [1, 2, 3]);
      });
    },
  );

  test('sink write and stop errors are contained', () {
    fakeAsync((async) {
      final r = Rig(async, sink: FakeSink(failWrites: true, failStop: true));
      r.hello();
      for (var i = 1; i <= 3; i++) {
        r.audio(i);
      }
      r.async.elapse(const Duration(milliseconds: 50));
      r.rx(Packet.end(9, pin));
      expect(r.sink.stops, 1);
      expect(r.state, TvState.connected);
    });
  });

  rig('a failing send does not skip the rest of packet handling', (r) {
    r.port.failSend = true;
    r.hello();
    expect(r.state, TvState.connected);
    r.audio(1);
    expect(r.engine.current.framesRx, 1);
  });

  rig(
    'stop cancels timers, closes the port, stops the sink and the status stream',
    (r) {
      r.hello();
      for (var i = 1; i <= 3; i++) {
        r.audio(i);
      }
      r.async.elapse(const Duration(milliseconds: 30));
      var done = false;
      r.engine.status.listen((_) {}, onDone: () => done = true);
      r.engine.stop();
      r.async.flushMicrotasks();
      expect(r.port.closed, isTrue);
      expect(r.sink.stops, 1);
      expect(r.async.pendingTimers, isEmpty);
      expect(done, isTrue);
    },
  );

  rig('wrong-PIN HELLO -> REJECT', (r) {
    r.rx(Packet.hello(1, 1));
    expect(decodePacket(r.port.sent.single.$1)!.type, PacketType.reject);
    expect(r.state, TvState.listening);
  });

  rig('bad magic dropped', (r) {
    r.port.ctl.add(Datagram(Uint8List.fromList([1, 2, 3]), a));
    r.async.flushMicrotasks();
    expect(r.port.sent, isEmpty);
  });

  rig('END flushes and stops the sink once', (r) {
    r.hello();
    for (var i = 1; i <= 3; i++) {
      r.audio(i);
    }
    r.ticks(3);
    expect(r.sink.starts, 1);
    r.audio(4);
    r.rx(Packet.end(5, pin));
    expect(r.buffer.depth, 0);
    expect(r.state, TvState.connected);
    expect(r.sink.stops, 1);
  });

  rig('500 ms without accepted AUDIO -> connected and flushed', (r) {
    r.hello();
    r.audio(1);
    r.async.elapse(const Duration(milliseconds: 499));
    expect(r.state, TvState.receiving);
    r.async.elapse(const Duration(milliseconds: 1));
    expect(r.state, TvState.connected);
    expect(r.buffer.depth, 0);
  });

  rig('no HELLO for 6 s -> listening', (r) {
    r.hello();
    r.async.elapse(const Duration(seconds: 6));
    expect(r.state, TvState.listening);
  });

  rig('new phone flushes the buffer (review 1a)', (r) {
    r.hello();
    for (var i = 1000; i <= 1010; i++) {
      r.audio(i);
      r.ticks(1);
    }
    r.hello(b);
    expect(r.buffer.depth, 0);
    for (var i = 0; i < 3; i++) {
      r.audio(i, b);
    }
    expect(r.buffer.pop(), isNotNull);
  });

  rig('same-peer restart without END recovers (review 1b)', (r) {
    r.hello();
    for (var i = 1000; i <= 1010; i++) {
      r.audio(i);
      r.ticks(1);
    }
    for (var i = 0; i < 3; i++) {
      r.audio(i); // stale: must not refresh the 500 ms timer
    }
    expect(r.engine.current.framesDropped, 3);
    r.async.elapse(const Duration(milliseconds: 500));
    expect(r.buffer.depth, 0);
    for (var i = 3; i < 6; i++) {
      r.audio(i);
    }
    expect(r.buffer.pop(), isNotNull);
  });

  test('bind supervisor backs off 1, 2, 4 s then succeeds (review 4)', () {
    fakeAsync((async) {
      final attempts = <int>[];
      late Rig r;
      r = Rig(
        async,
        bind: () async {
          attempts.add(async.elapsed.inSeconds);
          if (attempts.length <= 3) throw const SocketLikeException();
          return r.port;
        },
      );
      async.elapse(const Duration(seconds: 10));
      expect(attempts, [0, 1, 3, 7]);
    });
  });

  test('bind delay caps at 5 s', () {
    fakeAsync((async) {
      final attempts = <int>[];
      Rig(
        async,
        bind: () async {
          attempts.add(async.elapsed.inSeconds);
          throw const SocketLikeException();
        },
      );
      async.elapse(const Duration(seconds: 20));
      expect(attempts, [0, 1, 3, 7, 12, 17]);
    });
  });

  test('rebinds 1 s after the socket closes', () {
    fakeAsync((async) {
      final ports = <FakePort>[];
      final r = Rig(
        async,
        bind: () async {
          final p = FakePort();
          ports.add(p);
          return p;
        },
      );
      ports.first.ctl.close();
      async.elapse(const Duration(seconds: 1));
      expect(ports.length, 2);
      ports.last.ctl.add(Datagram(encodePacket(Packet.hello(1, pin)), a));
      async.flushMicrotasks();
      expect(ports.last.sent, hasLength(1));
      expect(r.state, TvState.connected);
    });
  });
}

class SocketLikeException implements Exception {
  const SocketLikeException();
}
