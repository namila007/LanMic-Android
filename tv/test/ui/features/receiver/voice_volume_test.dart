// ignore_for_file: unused_element_parameter
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanmic_tv/data/services/network_info_service.dart';
import 'package:lanmic_tv/data/services/pin_store.dart';
import 'package:lanmic_tv/data/services/voice_volume_store.dart';
import 'package:lanmic_tv/domain/receiver_status.dart';
import 'package:lanmic_tv/ui/features/receiver/view_models/receiver_view_model.dart';
import 'package:lanmic_tv/ui/features/receiver/view_models/stats_line.dart';

class _Source implements ReceiverStatusSource {
  final ctl = StreamController<ReceiverStatus>.broadcast(sync: true);
  @override
  Stream<ReceiverStatus> get status => ctl.stream;
}

class _Net extends NetworkInfoService {
  @override
  Future<String?> localIpv4() async => '192.168.1.42';
}

class _Pins implements PinStore {
  @override
  Future<int> load() async => 482917;
}

class _Volume implements VoiceVolumeStore {
  _Volume([this.value = 0]);
  int value;
  @override
  Future<int> load() async => value;
  @override
  Future<void> save(int db) async => value = db;
}

class _SlowVolume implements VoiceVolumeStore {
  final writes = <int>[];
  @override
  Future<int> load() async => 0;
  @override
  Future<void> save(int db) async {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    writes.add(db);
  }
}

void main() {
  late _Source source;
  late _Volume store;
  late List<int> gains;

  ReceiverViewModel build() => ReceiverViewModel(
    source: source,
    net: _Net(),
    pins: _Pins(),
    volume: store,
    setPlaybackGain: (db) async => gains.add(db),
  );

  setUp(() {
    source = _Source();
    store = _Volume();
    gains = [];
  });

  test('voice volume is restored on init and applied', () async {
    store.value = -4;
    final vm = build();
    await vm.init();
    expect(vm.voiceVolumeDb, -4);
    expect(gains, [-4]);
    vm.dispose();
  });

  test('D-pad steps by 1 dB, clamps to ±12, saves and applies', () async {
    final vm = build();
    await vm.init();
    await vm.stepVoiceVolume(1);
    await vm.stepVoiceVolume(1);
    for (var i = 0; i < 20; i++) {
      await vm.stepVoiceVolume(1);
    }
    expect(vm.voiceVolumeDb, 12);
    expect(store.value, 12);
    expect(gains.first, 0);
    expect(gains.sublist(1, 3), [1, 2]);
    expect(gains.last, 12);
    await vm.resetVoiceVolume();
    expect((vm.voiceVolumeDb, store.value, gains.last), (0, 0, 0));
    vm.dispose();
  });

  test('a change highlights the line for 2 s', () {
    fakeAsync((async) {
      final vm = build();
      vm.init();
      async.flushMicrotasks();
      expect(vm.voiceJustChanged, isFalse);
      vm.stepVoiceVolume(-1);
      async.flushMicrotasks();
      expect(vm.voiceJustChanged, isTrue);
      async.elapse(const Duration(milliseconds: 1900));
      vm.stepVoiceVolume(-1); // another press restarts the 2 s
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 1900));
      expect(vm.voiceJustChanged, isTrue);
      async.elapse(const Duration(milliseconds: 200));
      expect(vm.voiceJustChanged, isFalse);
      vm.dispose();
    });
  });

  test('voice limited follows the engine flag', () async {
    final vm = build();
    await vm.init();
    source.ctl.add(const ReceiverStatus(TvState.receiving, gainLimiting: true));
    expect(vm.voiceLimited, isTrue);
    source.ctl.add(const ReceiverStatus(TvState.receiving, gainLimiting: false));
    expect(vm.voiceLimited, isFalse);
    vm.dispose();
  });

  test('dB text uses a real minus sign', () {
    expect(dbText(0), '0 dB');
    expect(dbText(12), '+12 dB');
    expect(dbText(-3), '−3 dB');
  });

  test('holding Up: a burst of presses writes prefs at most twice, ending on the final value', () {
    fakeAsync((async) {
      final slow = _SlowVolume();
      final vm = ReceiverViewModel(
        source: source,
        net: _Net(),
        pins: _Pins(),
        volume: slow,
        setPlaybackGain: (db) async => gains.add(db),
      );
      vm.init();
      async.flushMicrotasks();
      for (var i = 0; i < 10; i++) {
        vm.stepVoiceVolume(1); // key repeat: nobody awaits
        async.elapse(const Duration(milliseconds: 10));
      }
      async.elapse(const Duration(seconds: 3));
      expect(slow.writes.length, lessThanOrEqualTo(2));
      expect(slow.writes.last, 10);
      expect(gains.last, 10); // every step still reaches native at once
      vm.dispose();
    });
  });

  test('a step after dispose does nothing', () async {
    final vm = build();
    await vm.init();
    vm.dispose();
    await vm.stepVoiceVolume(1);
    expect(store.value, 0);
  });
}
