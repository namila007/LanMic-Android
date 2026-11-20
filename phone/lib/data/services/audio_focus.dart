import 'package:audio_session/audio_session.dart';

/// Audio focus while the mic is open, so calls and other apps are reported.
abstract class AudioFocus {
  Future<void> activate();
  Future<void> deactivate();

  /// Fires when something else takes focus (call, alarm, other recorder).
  Stream<void> get interruptions;
}

class PluginAudioFocus implements AudioFocus {
  bool _configured = false;

  Future<AudioSession> _session() async {
    final s = await AudioSession.instance;
    if (!_configured) {
      await s.configure(const AudioSessionConfiguration.speech());
      _configured = true;
    }
    return s;
  }

  @override
  Future<void> activate() async => (await _session()).setActive(true);

  @override
  Future<void> deactivate() async => (await _session()).setActive(false);

  @override
  Stream<void> get interruptions =>
      Stream.fromFuture(AudioSession.instance)
          .asyncExpand((s) => s.interruptionEventStream)
          .where((e) => e.begin);
}
