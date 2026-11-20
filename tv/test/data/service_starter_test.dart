import 'package:flutter_test/flutter_test.dart';
import 'package:lanmic_tv/data/services/service_starter.dart';

class FakeApi implements ForegroundServiceApi {
  FakeApi(this.running);
  bool running;
  int starts = 0;
  @override
  Future<bool> isRunning() async => running;
  @override
  Future<void> start() async {
    await Future<void>.delayed(Duration.zero);
    starts++;
    running = true;
  }

  @override
  Future<void> stop() async => running = false;
}

void main() {
  test('running service is not started again', () async {
    final api = FakeApi(true);
    await ServiceStarter(api).ensureRunning();
    expect(api.starts, 0);
  });

  test('stopped service is started once', () async {
    final api = FakeApi(false);
    await ServiceStarter(api).ensureRunning();
    expect(api.starts, 1);
  });

  test('concurrent calls start it once', () async {
    final api = FakeApi(false);
    final s = ServiceStarter(api);
    await Future.wait([s.ensureRunning(), s.ensureRunning()]);
    expect(api.starts, 1);
  });
}
