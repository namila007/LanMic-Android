import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanmic_tv/data/services/network_info_service.dart';
import 'package:lanmic_tv/data/services/pin_store.dart';
import 'package:lanmic_tv/domain/receiver_status.dart';
import 'package:lanmic_tv/ui/features/receiver/view_models/receiver_view_model.dart';

class FakeSource implements ReceiverStatusSource {
  final ctl = StreamController<ReceiverStatus>.broadcast(sync: true);
  @override
  Stream<ReceiverStatus> get status => ctl.stream;
}

class FakeNet extends NetworkInfoService {
  String? ip = '192.168.1.42';
  @override
  Future<String?> localIpv4() async => ip;
}

class FakePins implements PinStore {
  @override
  Future<int> load() async => 482917;
}

void main() {
  test('init loads pin and address; null IP shows No network', () async {
    final net = FakeNet();
    final vm = ReceiverViewModel(
      source: FakeSource(),
      net: net,
      pins: FakePins(),
    );
    await vm.init();
    expect(
      (vm.pin, vm.address, vm.state),
      ('482917', '192.168.1.42', TvState.listening),
    );
    vm.dispose();
    net.ip = null;
    final vm2 = ReceiverViewModel(
      source: FakeSource(),
      net: net,
      pins: FakePins(),
    );
    await vm2.init();
    expect(vm2.address, 'No network');
    vm2.dispose();
  });

  test('address is re-read every 5 s and notifies only on change', () {
    fakeAsync((async) {
      final net = FakeNet();
      final vm = ReceiverViewModel(
        source: FakeSource(),
        net: net,
        pins: FakePins(),
      );
      vm.init();
      async.flushMicrotasks();
      var n = 0;
      vm.addListener(() => n++);
      async.elapse(const Duration(seconds: 5));
      expect(n, 0);
      net.ip = '10.0.0.7';
      async.elapse(const Duration(seconds: 5));
      expect((vm.address, n), ('10.0.0.7', 1));
      vm.dispose();
    });
  });

  test('status updates drive state', () async {
    final src = FakeSource();
    final vm = ReceiverViewModel(source: src, net: FakeNet(), pins: FakePins());
    await vm.init();
    src.ctl.add(const ReceiverStatus(TvState.receiving));
    expect(vm.state, TvState.receiving);
    vm.dispose();
  });

  test('notifies on a stats-only change, not on an identical status', () async {
    final src = FakeSource();
    final vm = ReceiverViewModel(source: src, net: FakeNet(), pins: FakePins());
    await vm.init();
    var n = 0;
    vm.addListener(() => n++);
    src.ctl.add(const ReceiverStatus(TvState.receiving));
    src.ctl.add(const ReceiverStatus(TvState.receiving, lostPermille: 3));
    src.ctl.add(const ReceiverStatus(TvState.receiving, lostPermille: 3));
    expect(n, 2);
    expect(vm.status.lostPermille, 3);
    vm.dispose();
  });

  test('no notify when only counters change', () async {
    final src = FakeSource();
    final vm = ReceiverViewModel(source: src, net: FakeNet(), pins: FakePins());
    await vm.init();
    src.ctl.add(const ReceiverStatus(TvState.receiving, lostPermille: 3));
    var n = 0;
    vm.addListener(() => n++);
    src.ctl.add(
      const ReceiverStatus(
        TvState.receiving,
        lostPermille: 3,
        framesRx: 50,
        framesDropped: 1,
        underruns: 2,
      ),
    );
    expect(n, 0);
    src.ctl.add(const ReceiverStatus(TvState.receiving, lostPermille: 4));
    expect(n, 1);
    vm.dispose();
  });
}
