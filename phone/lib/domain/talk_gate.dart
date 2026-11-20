import 'phone_state.dart';

/// Opens/closes the mic. Every closer goes through `_close`.
class TalkGate {
  TalkGate({
    required this.onOpen,
    required this.onClose,
    required this.sendEnd,
  });

  final void Function() onOpen;
  final void Function() onClose;
  final void Function() sendEnd;

  TalkMode _mode = TalkMode.hold;
  bool _open = false;
  bool _enabled = false;

  TalkMode get mode => _mode;
  bool get isOpen => _open;
  bool get enabled => _enabled;
  set enabled(bool v) {
    _enabled = v;
    if (!v) _close();
  }

  void _openGate() {
    if (!_enabled || _open) return;
    _open = true;
    onOpen();
  }

  void _close() {
    if (!_open) return;
    _open = false;
    onClose();
    sendEnd();
    sendEnd(); // shortcut: back-to-back, correlated loss possible; upgrade if TV logs miss END
  }

  void press() {
    if (_mode == TalkMode.hold) _openGate();
  }

  void release() {
    if (_mode == TalkMode.hold) _close();
  }

  void tap() {
    if (_mode != TalkMode.keep) return;
    _open ? _close() : _openGate();
  }

  void setMode(TalkMode m) {
    _close();
    _mode = m;
  }

  void backgrounded() {
    if (_mode == TalkMode.hold) _close();
  }

  void interrupted() => _close();
  void stop() => _close();
}
