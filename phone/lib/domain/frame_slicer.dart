import 'dart:typed_data';

import 'package:lanmic_protocol/lanmic_protocol.dart';

/// Re-cuts arbitrary-size recorder chunks into exact 960 B frames.
class FrameSlicer {
  final _buf = BytesBuilder(copy: false);

  int get pending => _buf.length;

  Iterable<Uint8List> add(Uint8List chunk) {
    _buf.add(chunk);
    if (_buf.length < kFrameBytes) return const [];
    final all = _buf.takeBytes();
    final n = all.length ~/ kFrameBytes;
    final frames = [
      for (var i = 0; i < n; i++)
        Uint8List.fromList(all.sublist(i * kFrameBytes, (i + 1) * kFrameBytes)),
    ];
    _buf.add(Uint8List.fromList(all.sublist(n * kFrameBytes)));
    return frames;
  }

  void reset() => _buf.clear();
}
