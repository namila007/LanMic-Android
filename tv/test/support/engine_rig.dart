import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanmic_protocol/lanmic_protocol.dart';
import 'package:lanmic_tv/domain/audio_engine.dart';
import 'package:lanmic_tv/domain/receiver_engine.dart';
import 'package:lanmic_tv/domain/receiver_status.dart';
import 'package:lanmic_tv/domain/session_registry.dart';

const pin = 482917;
const a = Peer('10.0.0.1', 4000);
const b = Peer('10.0.0.2', 4001);

/// Records accept/send in one ordered log; stats are scripted by the test.
class FakeAudioEngine implements AudioEngine {
  final ctl = StreamController<Datagram>(sync: true);
  final events = <String>[]; // 'accept <peer>' / 'accept null' / 'send <type>'
  final sent = <(Uint8List, Peer)>[];
  final accepts = <Peer?>[];
  AudioStats statsValue = const AudioStats();
  Completer<AudioStats>? hold; // makes stats() hang until completed
  int starts = 0, stops = 0, statsCalls = 0;
  bool failStats = false, throwOnSend = false;
  int failAccepts = 0; // the next N accept() calls fail

  @override
  Stream<Datagram> get packets => ctl.stream;
  @override
  Stream<String> get socketEvents => const Stream.empty();
  @override
  Future<void> start() async => starts++;
  @override
  Future<void> stop() async => stops++;
  @override
  Future<void> accept(Peer? peer, int pin) async {
    accepts.add(peer);
    events.add('accept $peer');
    if (failAccepts > 0) {
      failAccepts--;
      throw StateError('accept failed');
    }
  }

  @override
  void send(Uint8List d, Peer to) {
    if (throwOnSend) throw StateError('send failed');
    sent.add((d, to));
    events.add('send ${decodePacket(d)!.type.name}');
  }

  @override
  Future<AudioStats> stats() {
    statsCalls++;
    if (failStats) return Future.error(StateError('stats failed'));
    return hold?.future ?? Future.value(statsValue);
  }
}

class Rig {
  Rig(
    this.async, {
    WifiBand band = WifiBand.ghz5,
    void Function()? onPhoneActive,
  }) {
    engine = ReceiverEngine(
      audio: audio,
      registry: SessionRegistry(pin: pin, name: 'Chromecast', now: now),
      now: now,
      wifiBand: () => band,
      onPhoneActive: onPhoneActive,
    );
    engine.start();
    async.flushMicrotasks();
  }
  final FakeAsync async;
  final audio = FakeAudioEngine();
  late final ReceiverEngine engine;
  DateTime now() => DateTime(2026).add(async.elapsed);

  void rx(Packet p, [Peer from = a]) {
    audio.ctl.add(Datagram(encodePacket(p), from));
    async.flushMicrotasks();
  }

  void hello([Peer from = a, HelloInfo? info]) =>
      rx(Packet.hello(1, pin, info), from);

  /// Native stats as if audio is arriving (age < 500 ms), then lets a poll pick them up.
  void setStats(AudioStats s) {
    audio.statsValue = s;
    async.elapse(const Duration(milliseconds: 250));
  }

  TvState get state => engine.current.state;
}

void rig(String name, void Function(Rig r) body) =>
    test(name, () => fakeAsync((async) => body(Rig(async))));
