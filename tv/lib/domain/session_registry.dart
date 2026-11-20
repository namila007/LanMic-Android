import 'package:lanmic_protocol/lanmic_protocol.dart';

class Peer {
  const Peer(this.host, this.port);
  final String host;
  final int port;

  @override
  bool operator ==(Object other) =>
      other is Peer && other.host == host && other.port == port;
  @override
  int get hashCode => Object.hash(host, port);
  @override
  String toString() => '$host:$port';
}

class SessionResult {
  const SessionResult({this.reply, this.audio = false, this.end = false});
  static const none = SessionResult();
  final Packet? reply;
  final bool audio;
  final bool end;
}

const _phoneTimeout = Duration(seconds: 6);
const _rejectInterval = Duration(seconds: 1);

class SessionRegistry {
  SessionRegistry({required this.pin, required this.name, required this.now});

  final int pin;
  final String name;
  final DateTime Function() now;
  Peer? _phone;
  DateTime? _lastHelloAt;
  final _lastReject = <String, DateTime>{};

  Peer? get activePhone {
    final at = _lastHelloAt;
    return at != null && now().difference(at) < _phoneTimeout ? _phone : null;
  }

  /// [reply] is to be sent back to [from].
  SessionResult onPacket(Packet p, Peer from) {
    switch (p.type) {
      case PacketType.ack || PacketType.reject:
        return SessionResult.none;
      case PacketType.hello:
        if (p.pin != pin) return _reject(p, from);
        _phone = from;
        _lastHelloAt = now();
        return SessionResult(reply: Packet.ack(p.seq, pin, name));
      case PacketType.audio:
        return SessionResult(audio: _fromActive(p, from));
      case PacketType.end:
        return SessionResult(end: _fromActive(p, from));
    }
  }

  bool _fromActive(Packet p, Peer from) => p.pin == pin && activePhone == from;

  // Keyed by host so a port-scanning flood cannot dodge the limit.
  SessionResult _reject(Packet p, Peer from) {
    final t = now(), last = _lastReject[from.host];
    if (last != null && t.difference(last) < _rejectInterval) {
      return SessionResult.none;
    }
    _lastReject[from.host] = t;
    return SessionResult(reply: Packet.reject(p.seq, p.pin));
  }
}
