import 'package:flutter_test/flutter_test.dart';
import 'package:lanmic/domain/connection_machine.dart';
import 'package:lanmic/domain/phone_state.dart';

final t0 = DateTime.utc(2026, 1, 1);
DateTime at(int ms) => t0.add(Duration(milliseconds: ms));

void main() {
  late int hellos;
  late ConnectionMachine m;
  setUp(() {
    hellos = 0;
    m = ConnectionMachine(sendHello: () => hellos++);
  });

  void tickTo(int fromMs, int toMs, [int step = 250]) {
    for (var t = fromMs; t <= toMs; t += step) {
      m.tick(at(t));
    }
  }

  test('connect -> connecting, HELLO now, +1 s, +2 s, none at +2.5 s', () {
    m.connect(at(0));
    expect(m.state, PhoneState.connecting);
    expect(hellos, 1);
    m.tick(at(750));
    expect(hellos, 1);
    m.tick(at(1000));
    expect(hellos, 2);
    m.tick(at(2000));
    expect(hellos, 3);
    tickTo(2250, 2750);
    expect(hellos, 3);
  });

  test('ACK with name -> connected, tvName set', () {
    m.connect(at(0));
    m.onAck('Living Room', at(100));
    expect(m.state, PhoneState.connected);
    expect(m.tvName, 'Living Room');
  });

  test('ACK with null or empty name -> connected, tvName null', () {
    m.connect(at(0));
    m.onAck('', at(100));
    expect(m.state, PhoneState.connected);
    expect(m.tvName, isNull);
  });

  test('no ACK: connecting at 2999, noResponse at 3000', () {
    m.connect(at(0));
    m.tick(at(2999));
    expect(m.state, PhoneState.connecting);
    m.tick(at(3000));
    expect(m.state, PhoneState.noResponse);
  });

  test('connect again from noResponse restarts retries', () {
    m.connect(at(0));
    m.tick(at(3000));
    hellos = 0;
    m.connect(at(5000));
    expect(m.state, PhoneState.connecting);
    expect(hellos, 1);
    m.tick(at(6000));
    expect(hellos, 2);
  });

  test('REJECT while connecting -> wrongPin', () {
    m.connect(at(0));
    m.onReject();
    expect(m.state, PhoneState.wrongPin);
  });

  test('REJECT while connected -> wrongPin', () {
    m.connect(at(0));
    m.onAck('x', at(0));
    m.onReject();
    expect(m.state, PhoneState.wrongPin);
  });

  test('heartbeat: connected at 0 -> HELLO at 2000, 4000', () {
    m.connect(at(0));
    m.onAck('x', at(0));
    hellos = 0;
    m.tick(at(1999));
    expect(hellos, 0);
    m.tick(at(2000));
    expect(hellos, 1);
    m.tick(at(4000));
    expect(hellos, 2);
  });

  test('ACK at 2100 resets: no lost at 6000, lost at 8100', () {
    m.connect(at(0));
    m.onAck('x', at(0));
    tickTo(0, 2000);
    m.onAck('x', at(2100));
    tickTo(2250, 6000);
    expect(m.state, PhoneState.connected);
    tickTo(6250, 8000);
    expect(m.state, PhoneState.connected);
    m.tick(at(8100));
    expect(m.state, PhoneState.lost);
  });

  test('lost at exactly 6000 ms since last ACK', () {
    m.connect(at(0));
    m.onAck('x', at(0));
    m.tick(at(5999));
    expect(m.state, PhoneState.connected);
    m.tick(at(6000));
    expect(m.state, PhoneState.lost);
  });

  test('lost keeps HELLO every 2 s with no cap (10 min = 300)', () {
    m.connect(at(0));
    m.onAck('x', at(0));
    tickTo(0, 6000);
    expect(m.state, PhoneState.lost);
    hellos = 0;
    tickTo(6250, 6000 + 600000);
    expect(hellos, 300);
  });

  test('ACK in lost -> connected', () {
    m.connect(at(0));
    m.onAck('x', at(0));
    m.tick(at(6000));
    m.onAck('x', at(7000));
    expect(m.state, PhoneState.connected);
  });

  test('clock jump: tick(60000) from connected -> lost', () {
    m.connect(at(0));
    m.onAck('x', at(0));
    m.tick(at(60000));
    expect(m.state, PhoneState.lost);
  });

  test('onSendFailure: connected -> lost, connecting -> noResponse', () {
    m.connect(at(0));
    m.onSendFailure();
    expect(m.state, PhoneState.noResponse);
    m.connect(at(10));
    m.onAck('x', at(20));
    m.onSendFailure();
    expect(m.state, PhoneState.lost);
  });

  test('disconnect -> disconnected, no further HELLO', () {
    m.connect(at(0));
    m.onAck('x', at(0));
    m.disconnect();
    expect(m.state, PhoneState.disconnected);
    expect(m.tvName, isNull);
    hellos = 0;
    tickTo(0, 20000);
    expect(hellos, 0);
  });

  test('ACK and REJECT after disconnect are ignored', () {
    m.connect(at(0));
    m.disconnect();
    m.onAck('x', at(1));
    expect(m.state, PhoneState.disconnected);
    m.onReject();
    expect(m.state, PhoneState.disconnected);
  });

  test('onChange fires on state change only', () {
    var n = 0;
    final mm = ConnectionMachine(sendHello: () {}, onChange: () => n++);
    mm.connect(at(0));
    expect(n, 1);
    mm.tick(at(100));
    expect(n, 1);
  });

  test('rebound: HELLO now, state kept, 6 s lost timeout unchanged; ignored when idle', () {
    m.rebound(at(0));
    expect(hellos, 0);
    m.connect(at(0));
    m.onAck(null, at(100));
    m.rebound(at(5000));
    expect(m.state, PhoneState.connected);
    expect(hellos, 2);
    m.tick(at(6200));
    expect(m.state, PhoneState.lost); // measured from the last ACK, not from the rebind
  });
}
