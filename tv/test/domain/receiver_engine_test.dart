import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanmic_protocol/lanmic_protocol.dart';
import 'package:lanmic_tv/domain/audio_engine.dart';
import 'package:lanmic_tv/domain/receiver_status.dart';

import '../support/engine_rig.dart';

void main() {
  rig('HELLO from a new phone: accept(peer) is called before the ACK is sent', (r) {
    r.hello();
    expect(r.audio.events, ['accept $a', 'send ack']);
    final (bytes, to) = r.audio.sent.single;
    expect(to, a);
    final ack = decodePacket(bytes)!;
    expect((ack.type, ack.ackName), (PacketType.ack, 'Chromecast'));
    expect(r.state, TvState.connected);
    r.hello(); // same phone again: no second accept
    expect(r.audio.accepts, [a]);
  });

  rig('a different phone takes over: accept(b)', (r) {
    r.hello();
    r.hello(b);
    expect(r.audio.accepts, [a, b]);
  });

  rig('activePhone timeout calls accept(null)', (r) {
    r.hello();
    r.async.elapse(const Duration(seconds: 6, milliseconds: 200));
    expect(r.audio.accepts, [a, null]);
    expect(r.state, TvState.listening);
  });

  rig('wrong PIN -> REJECT, no accept', (r) {
    r.rx(Packet.hello(1, 1));
    expect(decodePacket(r.audio.sent.single.$1)!.type, PacketType.reject);
    expect(r.audio.accepts, isEmpty);
    expect(r.state, TvState.listening);
  });

  rig('bad magic dropped', (r) {
    r.audio.ctl.add(Datagram(Uint8List.fromList([1, 2, 3]), a));
    r.async.flushMicrotasks();
    expect(r.audio.sent, isEmpty);
  });

  rig('receiving iff lastAudioAgeMs < 500', (r) {
    r.hello();
    r.setStats(const AudioStats(lastAudioAgeMs: 499));
    expect(r.state, TvState.receiving);
    r.setStats(const AudioStats(lastAudioAgeMs: 500));
    expect(r.state, TvState.connected);
    r.setStats(const AudioStats());
    expect(r.state, TvState.connected);
    r.async.elapse(const Duration(seconds: 7)); // phone gone
    expect(r.state, TvState.listening);
  });

  rig('stats() throwing drops to connected, not receiving', (r) {
    r.hello();
    r.setStats(const AudioStats(lastAudioAgeMs: 10, received: 5));
    expect(r.state, TvState.receiving);
    r.audio.failStats = true;
    r.async.elapse(const Duration(milliseconds: 300));
    expect(r.state, TvState.connected);
    expect(r.engine.stats, isNull);
  });

  rig('accept failure is retried', (r) {
    r.audio.failAccepts = 1;
    r.hello();
    r.async.elapse(const Duration(milliseconds: 250));
    expect(r.audio.accepts, [a, a]);
    r.async.elapse(const Duration(seconds: 1));
    expect(r.audio.accepts, [a, a]); // accepted now: no more retries
  });

  rig('send throwing synchronously does not escape the timer', (r) {
    r.hello();
    r.audio.throwOnSend = true;
    r.async.elapse(const Duration(seconds: 2)); // the 1 s STATS send throws inside the periodic timer
    r.rx(Packet.hello(1, pin)); // and so does the ACK; handling goes on
    expect(r.state, TvState.connected);
  });

  rig('stats poll does not overlap', (r) {
    r.audio.hold = Completer<AudioStats>();
    r.async.elapse(const Duration(seconds: 1));
    expect(r.audio.statsCalls, 1);
    r.audio.hold!.complete(const AudioStats());
    r.async.elapse(const Duration(milliseconds: 250));
    expect(r.audio.statsCalls, 2);
  });

  rig('status counters map received/late/lost', (r) {
    r.hello();
    r.setStats(const AudioStats(received: 90, late: 4, lost: 7, lastAudioAgeMs: 10));
    final s = r.engine.current;
    expect((s.framesRx, s.framesDropped, s.underruns), (90, 4, 7));
  });

  rig('stop stops the engine, cancels timers and closes the status stream', (r) {
    r.hello();
    var done = false;
    r.engine.status.listen((_) {}, onDone: () => done = true);
    r.engine.stop();
    r.async.flushMicrotasks();
    expect(r.audio.stops, 1);
    expect(r.async.pendingTimers, isEmpty);
    expect(done, isTrue);
  });

  test('start starts the audio engine once', () {
    fakeAsync((async) {
      final r = Rig(async);
      expect(r.audio.starts, 1);
    });
  });
}
