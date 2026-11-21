/// Watches the native send-error counter: when it rises on every poll for [polls] in a row (about 1 s at
/// 10 Hz) the socket is dead (e.g. Android blocks a backgrounded app) and must be rebound. Fires once per
/// failure run; any poll without new errors re-arms it.
class SendErrorMonitor {
  SendErrorMonitor({this.polls = 10});

  final int polls;
  int _last = 0, _rising = 0;
  bool _fired = false;

  bool add(int sendErrors) {
    if (sendErrors > _last) {
      _rising++;
    } else {
      _rising = 0;
      _fired = false;
    }
    _last = sendErrors;
    if (_rising < polls || _fired) return false;
    return _fired = true;
  }
}
