import 'phone_state.dart';

const _retry = Duration(seconds: 1);
const _noResponse = Duration(seconds: 3);
const _heartbeat = Duration(seconds: 2);
const _lostAfter = Duration(seconds: 6);

/// Connection state; time comes only through `now` params so tests need no clock.
class ConnectionMachine {
  ConnectionMachine({required this.sendHello, this.onChange});

  final void Function() sendHello;
  final void Function()? onChange;

  PhoneState _state = PhoneState.disconnected;
  String? _tvName;
  DateTime _since = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _nextHello = DateTime.fromMillisecondsSinceEpoch(0);
  int _helloCount = 0;

  PhoneState get state => _state;
  String? get tvName => _tvName;

  void _set(PhoneState s, {String? name}) {
    final changed = s != _state || name != _tvName;
    _state = s;
    _tvName = name;
    if (changed) onChange?.call();
  }

  void connect(DateTime now) {
    _since = now;
    _helloCount = 1;
    _nextHello = now.add(_retry);
    _set(PhoneState.connecting);
    sendHello();
  }

  void disconnect() => _set(PhoneState.disconnected);

  void onAck(String? name, DateTime now) {
    final s = _state;
    if (s != PhoneState.connecting &&
        s != PhoneState.connected &&
        s != PhoneState.lost) {
      return;
    }
    if (s != PhoneState.connected) _nextHello = now.add(_heartbeat);
    _since = now;
    _set(
      PhoneState.connected,
      name: (name == null || name.isEmpty) ? null : name,
    );
  }

  void onReject() {
    final s = _state;
    if (s == PhoneState.connecting ||
        s == PhoneState.connected ||
        s == PhoneState.lost) {
      _set(PhoneState.wrongPin);
    }
  }

  void onSendFailure() {
    if (_state == PhoneState.connecting) _set(PhoneState.noResponse);
    if (_state == PhoneState.connected) _set(PhoneState.lost);
  }

  void tick(DateTime now) {
    switch (_state) {
      case PhoneState.connecting:
        if (now.difference(_since) >= _noResponse) {
          _set(PhoneState.noResponse);
        } else if (_helloCount < 3 && !now.isBefore(_nextHello)) {
          _helloCount++;
          _nextHello = _nextHello.add(_retry);
          sendHello();
        }
      case PhoneState.connected || PhoneState.lost:
        if (_state == PhoneState.connected &&
            now.difference(_since) >= _lostAfter) {
          _set(PhoneState.lost);
        }
        if (!now.isBefore(_nextHello)) {
          _nextHello = now.add(_heartbeat);
          sendHello();
        }
      default:
    }
  }
}
