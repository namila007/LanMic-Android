import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanmic/data/services/permission_service.dart';
import 'package:lanmic/data/services/prefs_store.dart';
import 'package:lanmic/domain/phone_state.dart';
import 'package:lanmic/ui/features/mic/view_models/mic_view_model.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../support/fakes.dart';

Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  late List<String> log;
  late FakeSession session;
  late FakeMic mic;
  late FakePerms perms;
  late FakeFgs fgs;
  late FakeFocus focus;
  late DateTime clock;
  late List<bool> awake;
  late List<bool> lowLatency;
  late MicViewModel vm;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    log = [];
    session = FakeSession(log);
    mic = FakeMic(log);
    perms = FakePerms(log)..mic.add(PermStatus.granted);
    fgs = FakeFgs(log);
    focus = FakeFocus(log);
    clock = DateTime.utc(2026);
    awake = [];
    lowLatency = [];
    vm = MicViewModel(
      session: session,
      mic: mic,
      prefs: PrefsStore(),
      perms: perms,
      fgs: fgs,
      focus: focus,
      keepAwake: awake.add,
      now: () => clock,
      setLowLatency: lowLatency.add,
    );
    await vm.init();
  });

  Future<void> connected() async {
    await vm.connect('192.168.1.42', '482917');
    session.emit(PhoneState.connected);
    log.clear();
  }

  test('low-latency lock on at connected, off at disconnect', () async {
    await connected();
    expect(lowLatency, [true]);
    session.emit(PhoneState.disconnected);
    expect(lowLatency, [true, false]);
  });

  test('low-latency lock is held through lost and reconnect', () async {
    await connected();
    session.emit(PhoneState.lost);
    session.emit(PhoneState.connected);
    expect(lowLatency, [true]); // never released in between
    session.emit(PhoneState.lost);
    session.emit(PhoneState.disconnected);
    expect(lowLatency, [true, false]);
  });

  test('init restores ip and mode from prefs', () async {
    SharedPreferences.setMockInitialValues({'ip': '10.0.0.9', 'mode': 'keep'});
    final v = MicViewModel(
      session: session,
      mic: mic,
      prefs: PrefsStore(),
      perms: perms,
      fgs: fgs,
      focus: focus,
      keepAwake: (_) {},
      now: () => clock,
    );
    await v.init();
    expect(v.savedIp, '10.0.0.9');
    expect(v.mode, TalkMode.keep);
  });

  test('connect saves ip, never the PIN', () async {
    await vm.connect('192.168.1.42', '482917');
    final p = await SharedPreferences.getInstance();
    expect(p.getString('ip'), '192.168.1.42');
    expect(
      p.getKeys().any((k) => p.get(k).toString().contains('482917')),
      false,
    );
    expect(log, contains('connect 192.168.1.42 482917'));
  });

  test('invalid ip or pin -> ipError set, session untouched', () async {
    await vm.connect('tv.local', '482917');
    expect(vm.ipError, isNotNull);
    await vm.connect('192.168.1.42', '12');
    expect(vm.ipError, isNotNull);
    expect(log.where((l) => l.startsWith('connect')), isEmpty);
  });

  test('first run asks mic then notifications', () async {
    await vm.connect('192.168.1.42', '482917');
    expect(log.where((l) => l.startsWith('perm')), ['perm.mic', 'perm.notif']);
  });

  test('press before connected is ignored', () async {
    vm.pressTalk();
    expect(vm.state, PhoneState.disconnected);
    expect(log.where((l) => l.startsWith('mic')), isEmpty);
  });

  test('hold: press opens mic and goes live; release sends END x2', () async {
    await connected();
    vm.pressTalk();
    expect(vm.state, PhoneState.live);
    await settle();
    vm.releaseTalk();
    expect(vm.state, PhoneState.connected);
    expect(log, [
      'begin',
      'focus.on',
      'mic.open',
      'mic.close',
      'focus.off',
      'end',
      'end',
    ]);
  });

  test(
    'release before mic start completes -> closed, END x2, not live',
    () async {
      await connected();
      mic.openGate = Completer<void>();
      vm.pressTalk();
      vm.releaseTalk();
      mic.openGate!.complete();
      await settle();
      expect(vm.state, PhoneState.connected);
      expect(mic.isOpen, false);
      expect(log.where((l) => l == 'end').length, 2);
    },
  );

  test('released while permission pending -> not live after grant', () async {
    perms.mic
      ..clear()
      ..add(PermStatus.denied);
    await connected();
    final grant = Completer<PermStatus>();
    perms.mic
      ..clear()
      ..add(grant.future);
    vm.pressTalk();
    vm.releaseTalk();
    grant.complete(PermStatus.granted);
    await settle();
    expect(vm.state, PhoneState.connected);
    expect(log.where((l) => l.startsWith('mic')), isEmpty);
  });

  test('mic start failure -> not live', () async {
    await connected();
    mic.failOpen = true;
    vm.pressTalk();
    await settle();
    expect(vm.state, PhoneState.connected);
    expect(vm.micError, isNotNull);
  });

  test('setMode while live closes first', () async {
    await connected();
    vm.pressTalk();
    await settle();
    vm.setMode(TalkMode.keep);
    expect(vm.state, PhoneState.connected);
    expect(vm.mode, TalkMode.keep);
    expect(log.where((l) => l == 'end').length, 2);
  });

  test('keep: tap/tap toggles', () async {
    await connected();
    vm.setMode(TalkMode.keep);
    vm.tapTalk();
    expect(vm.state, PhoneState.live);
    await settle();
    vm.tapTalk();
    expect(vm.state, PhoneState.connected);
  });

  test('lost while live closes gate and mic', () async {
    await connected();
    vm.pressTalk();
    await settle();
    session.emit(PhoneState.lost);
    expect(vm.state, PhoneState.lost);
    expect(log, contains('mic.close'));
    session.emit(PhoneState.connected);
    expect(vm.state, PhoneState.connected);
  });

  test('liveFor counts from open using injected now', () async {
    await connected();
    vm.pressTalk();
    clock = clock.add(const Duration(seconds: 7));
    expect(vm.liveFor, const Duration(seconds: 7));
    vm.releaseTalk();
    expect(vm.liveFor, Duration.zero);
  });

  test(
    'connected -> keepAwake(true), disconnected -> keepAwake(false)',
    () async {
      await connected();
      expect(awake, [true]);
      await vm.disconnect();
      expect(awake.last, false);
      expect(vm.state, PhoneState.disconnected);
    },
  );

  test('mic permanently denied -> micPerm set, press ignored', () async {
    perms.mic
      ..clear()
      ..add(PermStatus.permanentlyDenied);
    await connected();
    expect(vm.micPerm, PermStatus.permanentlyDenied);
    vm.pressTalk();
    expect(vm.state, PhoneState.connected);
  });

  test(
    'interruption while live closes, shows call banner, clears on next press',
    () async {
      await connected();
      vm.pressTalk();
      await settle();
      vm.onInterruption(true);
      expect(vm.state, PhoneState.connected);
      expect(vm.pausedByCall, true);
      vm.onInterruption(false);
      expect(vm.state, PhoneState.connected);
      vm.pressTalk();
      expect(vm.pausedByCall, false);
    },
  );

  group('background and interruptions', () {
    Future<void> live(TalkMode m) async {
      await connected();
      vm.setMode(m);
      m == TalkMode.keep ? vm.tapTalk() : vm.pressTalk();
      await settle();
    }

    test(
      'keep: go live starts the service then the mic; close stops both',
      () async {
        await live(TalkMode.keep);
        expect(
          log,
          containsAllInOrder(['begin', 'fgs.start Living Room', 'mic.open']),
        );
        vm.tapTalk();
        await settle();
        expect(log, containsAll(['mic.close', 'fgs.stop']));
      },
    );

    test('hold never starts the service', () async {
      await live(TalkMode.hold);
      vm.releaseTalk();
      expect(log.where((l) => l.startsWith('fgs')), isEmpty);
    });

    test('paused in hold closes with END x2; in keep stays live', () async {
      await live(TalkMode.hold);
      vm.onLifecycle(AppLifecycleState.paused);
      expect(vm.state, PhoneState.connected);
      expect(log.where((l) => l == 'end').length, 2);
      await live(TalkMode.keep);
      vm.onLifecycle(AppLifecycleState.paused);
      expect(vm.state, PhoneState.live);
    });

    test('inactive does not close hold, hidden does', () async {
      await live(TalkMode.hold);
      vm.onLifecycle(AppLifecycleState.inactive);
      expect(vm.state, PhoneState.live);
      vm.onLifecycle(AppLifecycleState.hidden);
      expect(vm.state, PhoneState.connected);
    });

    test('Stop pressed closes gate, mic and service', () async {
      await live(TalkMode.keep);
      log.clear();
      fgs.stopController.add(null);
      await settle();
      expect(vm.state, PhoneState.connected);
      expect(log, containsAll(['mic.close', 'fgs.stop', 'end']));
    });

    test('disconnect while live stops everything', () async {
      await live(TalkMode.keep);
      log.clear();
      await vm.disconnect();
      await settle();
      expect(log, containsAll(['mic.close', 'fgs.stop', 'end', 'disconnect']));
    });

    test('notifications denied in keep: flagged, still live', () async {
      fgs.notifications = false;
      await live(TalkMode.keep);
      expect(vm.notificationsOff, true);
      expect(vm.state, PhoneState.live);
    });

    test('service start failure: keep refuses to go live', () async {
      fgs.failStart = true;
      await live(TalkMode.keep);
      expect(vm.state, PhoneState.connected);
      expect(vm.micError, isNotNull);
      expect(log, isNot(contains('mic.open')));
    });

    test('closing while the service is starting leaves no service', () async {
      await connected();
      vm.setMode(TalkMode.keep);
      vm.tapTalk();
      vm.tapTalk();
      await settle();
      expect(log.where((l) => l == 'fgs.stop'), isNotEmpty);
      expect(log, isNot(contains('mic.open')));
    });

    test('silence: zero-filled chunks for 1 s pause Keep, no auto-resume', () {
      fakeAsync((a) {
        session.emit(PhoneState.connected);
        vm.setMode(TalkMode.keep);
        vm.tapTalk();
        a.flushMicrotasks();
        for (var i = 0; i < 12; i++) {
          mic.levels.add(0); // Android 10+ call: zero-filled PCM keeps flowing
          a.elapse(const Duration(milliseconds: 100));
        }
        expect(vm.state, PhoneState.connected);
        expect(vm.micError, isNotNull);
        expect(vm.pausedByCall, false);
        mic.levels.add(0.3); // audio returns: still not live again
        a.elapse(const Duration(seconds: 1));
        expect(vm.state, PhoneState.connected);
      });
    });

    test('real audio keeps the watchdog quiet', () {
      fakeAsync((a) {
        session.emit(PhoneState.connected);
        vm.pressTalk();
        a.flushMicrotasks();
        for (var i = 0; i < 30; i++) {
          mic.levels.add(0.1);
          a.elapse(const Duration(milliseconds: 100));
        }
        expect(vm.state, PhoneState.live);
      });
    });

    test('no chunks at all for 1 s also pauses', () {
      fakeAsync((a) {
        session.emit(PhoneState.connected);
        vm.pressTalk();
        a.flushMicrotasks();
        a.elapse(const Duration(milliseconds: 1100));
        expect(vm.state, PhoneState.connected);
      });
    });

    test('audio focus: activated before the mic, released on close', () async {
      await live(TalkMode.hold);
      expect(log, containsAllInOrder(['focus.on', 'mic.open']));
      vm.releaseTalk();
      expect(log, contains('focus.off'));
    });

    test(
      'focus interruption pauses Keep, shows call banner, no resume',
      () async {
        await live(TalkMode.keep);
        focus.interrupt.add(null);
        expect(vm.state, PhoneState.connected);
        expect(vm.pausedByCall, true);
        await settle();
        expect(vm.state, PhoneState.connected);
        expect(log, containsAll(['mic.close', 'fgs.stop']));
      },
    );
  });
}
