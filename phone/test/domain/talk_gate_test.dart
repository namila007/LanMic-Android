import 'package:flutter_test/flutter_test.dart';
import 'package:lanmic/domain/phone_state.dart';
import 'package:lanmic/domain/talk_gate.dart';

void main() {
  late List<String> log;
  late TalkGate g;
  setUp(() {
    log = [];
    g = TalkGate(
      onOpen: () => log.add('open'),
      onClose: () => log.add('close'),
      sendEnd: () => log.add('end'),
    )..enabled = true;
  });

  const closed = ['close', 'end', 'end'];

  test('hold: press opens, release closes', () {
    g.press();
    expect(g.isOpen, true);
    g.release();
    expect(g.isOpen, false);
    expect(log, ['open', ...closed]);
  });

  test('hold: tap ignored', () {
    g.tap();
    expect(log, isEmpty);
  });

  test('keep: tap opens, tap closes, press/release ignored', () {
    g.setMode(TalkMode.keep);
    g.press();
    g.release();
    expect(log, isEmpty);
    g.tap();
    expect(g.isOpen, true);
    g.tap();
    expect(log, ['open', ...closed]);
  });

  test('no onClose/END when already closed', () {
    g.release();
    g.interrupted();
    g.stop();
    expect(log, isEmpty);
  });

  test('setMode while open closes then switches', () {
    g.press();
    g.setMode(TalkMode.keep);
    expect(g.isOpen, false);
    expect(g.mode, TalkMode.keep);
    expect(log, ['open', ...closed]);
  });

  test('press while enabled=false ignored', () {
    g.enabled = false;
    g.press();
    expect(log, isEmpty);
  });

  test('enabled=false while open closes', () {
    g.press();
    g.enabled = false;
    expect(log, ['open', ...closed]);
  });

  test('backgrounded closes in hold, keeps open in keep', () {
    g.press();
    g.backgrounded();
    expect(g.isOpen, false);
    g.setMode(TalkMode.keep);
    g.tap();
    g.backgrounded();
    expect(g.isOpen, true);
  });

  test('interrupted closes in both modes', () {
    g.setMode(TalkMode.keep);
    g.tap();
    g.interrupted();
    expect(g.isOpen, false);
    g.setMode(TalkMode.hold);
    g.press();
    g.interrupted();
    expect(g.isOpen, false);
  });

  test('stop closes', () {
    g.press();
    g.stop();
    expect(log, ['open', ...closed]);
  });
}
