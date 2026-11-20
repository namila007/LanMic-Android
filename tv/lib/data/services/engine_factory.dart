import 'dart:typed_data';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:lanmic_protocol/lanmic_protocol.dart';
import 'package:pcm_out/pcm_out.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/jitter_buffer.dart';
import '../../domain/receiver_engine.dart';
import '../../domain/session_registry.dart';
import 'pin_store.dart';
import 'udp_socket_service.dart';

/// Adapts the plugin to the domain's [PcmSink] (the plugin cannot import app code).
class PcmOutSink implements PcmSink {
  final _out = PcmOut();
  @override
  Future<void> start() => _out.start();
  @override
  Future<void> write(Uint8List frame) => _out.write(frame);
  @override
  Future<void> stop() => _out.stop();
  @override
  Future<({int? latencyMs, int dropped})> stats() => _out.stats();
}

/// The real receiver pipeline: UDP -> session -> jitter buffer -> AudioTrack.
Future<ReceiverEngine> buildReceiverEngine(
  SharedPreferences prefs, {
  WifiBand Function()? wifiBand,
  void Function()? onPhoneActive,
}) async {
  final pin = await SharedPrefsPinStore(prefs).load();
  final name = (await DeviceInfoPlugin().androidInfo).model;
  return ReceiverEngine(
    bind: UdpSocketService.bind,
    registry: SessionRegistry(pin: pin, name: name, now: DateTime.now),
    buffer: JitterBuffer(),
    sink: PcmOutSink(),
    now: DateTime.now,
    wifiBand: wifiBand ?? () => WifiBand.unknown,
    onPhoneActive: onPhoneActive,
  );
}
