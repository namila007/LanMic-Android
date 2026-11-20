import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:lanmic_protocol/lanmic_protocol.dart';

typedef Incoming = ({Packet packet, InternetAddress from, int port});

/// One UDP socket: encoded bytes out, decoded packets in (malformed dropped).
///
/// dart:io reports an OS send failure (e.g. EPERM while Android blocks a
/// backgrounded app) asynchronously and closes the socket, so a closed socket
/// is replaced by a fresh one instead of silently dropping every later send.
class UdpSender {
  UdpSender._();

  static Future<UdpSender> bind() async {
    final s = UdpSender._();
    await s._open();
    return s;
  }

  final _in = StreamController<Incoming>.broadcast();
  RawDatagramSocket? _socket;
  bool _closed = false, _opening = false;
  DateTime _lastTry = DateTime(0);

  int get port => _socket?.port ?? 0;
  Stream<Incoming> get incoming => _in.stream;

  Future<void> _open() async {
    _opening = true;
    try {
      final s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      if (_closed) return s.close();
      try {
        // Android/Linux constants (IPPROTO_IP, IP_TOS = DSCP EF); best effort.
        s.setRawOption(RawSocketOption.fromInt(0, 1, 0xB8));
      } on Object {
        // unsupported: audio still flows unmarked
      }
      _socket = s;
      s.listen(
        (e) {
          if (e != RawSocketEvent.read) return;
          final d = s.receive();
          final p = d == null ? null : decodePacket(d.data);
          if (d != null && p != null) {
            _in.add((packet: p, from: d.address, port: d.port));
          }
        },
        onError: (Object _) => _lost(s), // the send already counted as lost
        onDone: () => _lost(s),
      );
    } on SocketException {
      // no socket yet; the next send retries
    } finally {
      _opening = false;
    }
  }

  void _lost(RawDatagramSocket s) {
    if (!identical(_socket, s)) return;
    _socket = null;
    s.close(); // no-op if dart:io already closed it
    if (!_closed && !_opening) unawaited(_open());
  }

  /// Throws [SocketException] when closed, rebinding, or the OS refuses the send.
  void send(Uint8List bytes, InternetAddress to, int port) {
    if (_closed) throw const SocketException('sender closed');
    final s = _socket;
    if (s == null) {
      // A failed bind retries at most once a second, not on every 10 ms frame.
      final now = DateTime.now();
      if (!_opening && now.difference(_lastTry) >= const Duration(seconds: 1)) {
        _lastTry = now;
        unawaited(_open());
      }
      throw const SocketException('socket rebinding');
    }
    s.send(bytes, to, port);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _socket?.close();
    _socket = null;
    await _in.close();
  }
}
