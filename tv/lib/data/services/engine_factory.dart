import 'dart:async';
import 'dart:developer' as dev;
import 'dart:typed_data';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:lanmic_protocol/lanmic_protocol.dart';
import 'package:pcm_out/pcm_out.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/audio_engine.dart';
import '../../domain/receiver_engine.dart';
import '../../domain/session_registry.dart';
import 'pin_store.dart';

/// Adapts the plugin to the domain's [AudioEngine] (the plugin cannot import app code).
class NativeAudioEngine implements AudioEngine {
  final _r = NativeReceiver();

  @override
  Stream<Datagram> get packets => _r.packets.map((e) => Datagram(e.data, Peer(e.host, e.port)));
  @override
  Stream<String> get socketEvents => _r.socketEvents;
  @override
  Future<void> start() => _r.start();
  @override
  Future<void> stop() => _r.stop();
  @override
  Future<void> accept(Peer? peer, int pin) =>
      _r.accept(peer?.host, peer?.port, peer == null ? null : pin);

  @override
  void send(Uint8List d, Peer to) =>
      unawaited(_r.send(d, to.host, to.port).catchError((Object e) { // e.g. ENETUNREACH: keep going
        dev.log('send failed: $e', name: 'lanmic');
      }));

  @override
  Future<AudioStats> stats() async {
    final s = await _r.stats();
    return AudioStats(
      received: s.received,
      played: s.played,
      lost: s.lost,
      discarded: s.discarded,
      late: s.late,
      depthMs: s.depthMs,
      targetMs: s.targetMs,
      jitterMs: s.jitterMs,
      lastAudioAgeMs: s.lastAudioAgeMs,
      latencyMs: s.latencyMs,
      open: s.open,
      exclusive: s.exclusive,
      mmap: s.mmap,
      burst: s.burst,
      bufferFrames: s.bufferFrames,
      xruns: s.xruns,
      limitedPermille: s.limitedPermille,
    );
  }
}

/// The real receiver: native UDP + Oboe output, protocol logic in Dart.
Future<ReceiverEngine> buildReceiverEngine(
  SharedPreferences prefs, {
  WifiBand Function()? wifiBand,
  void Function()? onPhoneActive,
}) async {
  final pin = await SharedPrefsPinStore(prefs).load();
  final name = (await DeviceInfoPlugin().androidInfo).model;
  return ReceiverEngine(
    audio: NativeAudioEngine(),
    registry: SessionRegistry(pin: pin, name: name, now: DateTime.now),
    now: DateTime.now,
    wifiBand: wifiBand ?? () => WifiBand.unknown,
    onPhoneActive: onPhoneActive,
  );
}
