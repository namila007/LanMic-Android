import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lanmic/data/services/permission_service.dart';
import 'package:lanmic/domain/phone_state.dart';
import 'package:lanmic/ui/features/mic/view_models/mic_view_model.dart';
import 'package:lanmic/ui/features/mic/views/stats_card.dart';

const _live = Color(0xFFD92D20);
const _ring = Color(0xFFFF453A);
const _blue = Color(0xFF0066CC);
const _disabled = Color(0xFF7A7A7A);
const _paused = Color(0xFF8A5A00);

class _Tokens {
  const _Tokens(
    this.bg,
    this.fg,
    this.muted,
    this.field,
    this.chipBg,
    this.card,
    this.segBg,
    this.err,
    this.accent,
    this.idle,
  );
  final Color bg, fg, muted, field, chipBg, card, segBg, err, accent, idle;
}

const _dark = _Tokens(
  Color(0xFF272729),
  Color(0xFFFFFFFF),
  Color(0xFFCCCCCC),
  Color(0xFF000000),
  Color(0xFF000000),
  Color(0xFF2A2A2C),
  Color(0xFF000000),
  Color(0xFFFF6B61),
  Color(0xFF2997FF),
  Color(0x29FFFFFF),
);
const _light = _Tokens(
  Color(0xFFF5F5F7),
  Color(0xFF1D1D1F),
  Color(0xFF333333),
  Color(0xFFF5F5F7),
  Color(0xFFFFFFFF),
  Color(0xFFFFFFFF),
  Color(0xFFE0E0E0),
  Color(0xFFD92D20),
  Color(0xFF0066CC),
  Color(0x1F000000),
);

const _chipDots = {
  PhoneState.disconnected: Color(0xFF8E8E93),
  PhoneState.connecting: Color(0xFF8E8E93),
  PhoneState.connected: Color(0xFF30D158),
  PhoneState.live: Color(0xFF30D158),
  PhoneState.noResponse: Color(0xFFFF453A),
  PhoneState.wrongPin: Color(0xFFFF453A),
  PhoneState.lost: Color(0xFFFF9F0A),
};

String chipLabel(PhoneState s, String? tvName) => switch (s) {
  PhoneState.disconnected => 'Not connected',
  PhoneState.connecting => 'Connecting…',
  PhoneState.noResponse => 'No response. Check IP and Wi-Fi.',
  PhoneState.wrongPin => 'Wrong PIN',
  PhoneState.lost => 'Connection lost. Retrying…',
  PhoneState.connected ||
  PhoneState.live => tvName == null ? 'Connected' : 'Connected · $tvName',
};

String _talkLabel(PhoneState s, TalkMode m) => switch (s) {
  PhoneState.disconnected ||
  PhoneState.connecting ||
  PhoneState.noResponse ||
  PhoneState.wrongPin => 'Connect first',
  PhoneState.connected => m == TalkMode.keep ? 'TAP TO TALK' : 'HOLD TO TALK',
  PhoneState.live => m == TalkMode.keep ? 'LIVE · TAP TO STOP' : 'TALKING…',
  PhoneState.lost => 'Reconnecting…',
};

class MicScreen extends StatefulWidget {
  const MicScreen({super.key, required this.viewModel});

  final MicViewModel viewModel;

  @override
  State<MicScreen> createState() => _MicScreenState();
}

class _MicScreenState extends State<MicScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  MicViewModel get _vm => widget.viewModel;
  late final _pin = TextEditingController();
  late final _addr = TextEditingController(text: _vm.savedIp ?? '');
  late final _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );
  Timer? _tick;
  bool _wasLive = false;
  TalkMode _wasMode = TalkMode.hold;

  PhoneState get _s => _vm.state;
  TalkMode get _mode => _vm.mode;
  bool get _isLive => _s == PhoneState.live;
  bool get _connected =>
      _s == PhoneState.connected || _isLive || _s == PhoneState.lost;
  bool get _talkDisabled =>
      !(_s == PhoneState.connected || _isLive) ||
      _vm.micPerm == PermStatus.permanentlyDenied;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _vm.addListener(_onVm);
    _syncLive();
  }

  // Haptics, pulse and the 1 s repaint all follow the view model's live state.
  void _onVm() {
    final wasLive = _wasLive;
    final wasMode = _wasMode;
    _syncLive();
    if (_isLive && !wasLive) HapticFeedback.mediumImpact();
    if (!_isLive && wasLive && wasMode == TalkMode.keep) {
      HapticFeedback.mediumImpact();
      HapticFeedback.mediumImpact();
    }
  }

  void _syncLive() {
    _wasMode = _mode;
    if (_isLive && !_wasLive) {
      _pulse.repeat();
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    }
    if (!_isLive && _wasLive) {
      _pulse.stop();
      _tick?.cancel();
      _tick = null;
    }
    _wasLive = _isLive;
  }

  String get _elapsed {
    final s = _vm.liveFor.inSeconds;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      _vm.onLifecycle(state);

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _vm.removeListener(_onVm);
    _tick?.cancel();
    _pulse.dispose();
    _pin.dispose();
    _addr.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _vm,
    builder: (context, _) => _screen(context),
  );

  Widget _screen(BuildContext context) {
    final t = Theme.of(context).brightness == Brightness.dark ? _dark : _light;
    return Scaffold(
      backgroundColor: t.bg,
      body: DefaultTextStyle.merge(
        style: TextStyle(color: t.fg, letterSpacing: -0.224),
        child: Column(
          children: [
            Container(
              color: Colors.black,
              padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
              height: 44 + MediaQuery.paddingOf(context).top,
              alignment: Alignment.center,
              child: const Text(
                'LAN Mic',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            ),
            if (_isLive && _mode == TalkMode.keep) const _Banner(),
            if (_vm.pausedByCall)
              const _Banner(text: 'Paused by a call', color: _paused),
            Expanded(
              // Fills the screen so the talk area centres and Disconnect sits
              // at the bottom, but still scrolls when the keyboard is up.
              child: CustomScrollView(
                slivers: [
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Align(
                            alignment: Alignment.centerLeft,
                            child: _chip(t),
                          ),
                          if (!_connected) ...[
                            const SizedBox(height: 20),
                            _card(t),
                          ] else if (_vm.link case final link?) ...[
                            const SizedBox(height: 20),
                            StatsCard(
                              link: link,
                              phoneBand: _vm.phoneBand,
                              detailsOpen: _vm.detailsOpen,
                              lost: _s == PhoneState.lost,
                              onToggle: _vm.toggleDetails,
                              fg: t.fg,
                              muted: t.muted,
                              card: t.card,
                              accent: t.accent,
                            ),
                          ],
                          const SizedBox(height: 20),
                          _segments(t),
                          const SizedBox(height: 24),
                          Center(child: _talk(t)),
                          const SizedBox(height: 12),
                          _level(t),
                          if (_vm.notificationsOff &&
                              _isLive &&
                              _mode == TalkMode.keep)
                            Text(
                              "Notifications are off. The Stop control won't show.",
                              textAlign: TextAlign.center,
                              style: TextStyle(fontSize: 14, color: t.muted),
                            ),
                          if (_vm.micError != null)
                            Text(
                              _vm.micError!,
                              textAlign: TextAlign.center,
                              style: TextStyle(fontSize: 14, color: t.err),
                            ),
                          if (_vm.micPerm == PermStatus.permanentlyDenied)
                            TextButton(
                              onPressed: _vm.openSettings,
                              child: const Text('Open settings'),
                            ),
                          const Spacer(),
                          if (_connected)
                            Center(
                              child: OutlinedButton(
                                onPressed: _vm.disconnect,
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: t.accent,
                                  side: BorderSide(color: t.accent),
                                  minimumSize: const Size(0, 44),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 24,
                                  ),
                                ),
                                child: const Text(
                                  'Disconnect',
                                  style: TextStyle(fontSize: 17),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(_Tokens t) => Container(
    height: 36,
    padding: const EdgeInsets.symmetric(horizontal: 16),
    decoration: BoxDecoration(
      color: t.chipBg,
      borderRadius: BorderRadius.circular(18),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _dot(10, _chipDots[_s]!),
        const SizedBox(width: 8),
        Text(chipLabel(_s, _vm.tvName), style: const TextStyle(fontSize: 14)),
      ],
    ),
  );

  Widget _card(_Tokens t) => Container(
    padding: const EdgeInsets.all(24),
    decoration: BoxDecoration(
      color: t.card,
      borderRadius: BorderRadius.circular(18),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _field(
          t,
          'TV address',
          _addr,
          17,
          0,
          TextInputType.number,
          hint: '192.168.1.42',
        ),
        const SizedBox(height: 12),
        _field(
          t,
          'PIN',
          _pin,
          20,
          6,
          TextInputType.number,
          hint: '6 digits',
          obscure: true,
          maxLength: 6,
        ),
        if (_s == PhoneState.wrongPin) ...[
          const SizedBox(height: 12),
          Text(
            'Wrong PIN. Check the number on the TV.',
            style: TextStyle(fontSize: 14, color: t.err),
          ),
        ],
        if (_vm.ipError != null) ...[
          const SizedBox(height: 12),
          Text(_vm.ipError!, style: TextStyle(fontSize: 14, color: t.err)),
        ],
        if (_vm.micPerm == PermStatus.denied) ...[
          const SizedBox(height: 12),
          Text(
            'LAN Mic needs the microphone to send your voice to the TV.',
            style: TextStyle(fontSize: 14, color: t.muted),
          ),
        ],
        const SizedBox(height: 16),
        FilledButton(
          onPressed: () => _vm.connect(_addr.text.trim(), _pin.text),
          style: FilledButton.styleFrom(
            backgroundColor: _blue,
            foregroundColor: Colors.white,
            minimumSize: const Size(0, 44),
          ),
          child: const Text(
            'Connect',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    ),
  );

  Widget _field(
    _Tokens t,
    String label,
    TextEditingController c,
    double size,
    double spacing,
    TextInputType type, {
    String? hint,
    bool obscure = false,
    int? maxLength,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: TextStyle(fontSize: 14, color: t.muted)),
      const SizedBox(height: 4),
      SizedBox(
        height: 44,
        child: TextField(
          controller: c,
          keyboardType: type,
          obscureText: obscure,
          maxLength: maxLength,
          style: TextStyle(fontSize: size, letterSpacing: spacing),
          decoration: InputDecoration(
            counterText: '',
            hintText: hint,
            filled: true,
            fillColor: t.field,
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide.none,
            ),
          ),
        ),
      ),
    ],
  );

  Widget _segments(_Tokens t) => Container(
    padding: const EdgeInsets.all(4),
    decoration: BoxDecoration(
      color: t.segBg,
      borderRadius: BorderRadius.circular(26),
    ),
    child: Row(
      children: [
        for (final (m, label) in [
          (TalkMode.hold, 'Hold to talk'),
          (TalkMode.keep, 'Keep talking'),
        ])
          Expanded(
            child: GestureDetector(
              onTap: () => _vm.setMode(m),
              child: Container(
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _mode == m ? _blue : Colors.transparent,
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: _mode == m ? Colors.white : t.muted,
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );

  Widget _talk(_Tokens t) {
    final dis = _talkDisabled;
    final fg = _isLive
        ? Colors.white
        : dis
        ? _disabled
        : t.fg;
    final accent = _isLive
        ? Colors.white
        : dis
        ? _disabled
        : t.accent;
    final border = _isLive
        ? _live
        : dis
        ? _disabled
        : t.accent;
    return SizedBox(
      width: 224,
      height: 224,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (_isLive)
            for (final delay in const [0.0, 0.5])
              AnimatedBuilder(
                animation: _pulse,
                builder: (_, _) {
                  final p = (_pulse.value + delay) % 1;
                  return Opacity(
                    opacity: 0.7 * (1 - p),
                    child: Transform.scale(
                      scale: 1 + 0.22 * p,
                      child: Container(
                        width: 200,
                        height: 200,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: _ring, width: 2),
                        ),
                      ),
                    ),
                  );
                },
              ),
          Semantics(
            // Stable key: the pulse rings are inserted before this when live,
            // and without it the button remounts mid-press and loses the lift.
            key: const ValueKey('talk'),
            button: true,
            enabled: !dis,
            label: _mode == TalkMode.keep
                ? 'Talk button, tap to toggle'
                : 'Talk button, hold to talk',
            // Raw pointer events for hold: a tap would cancel on finger drift.
            child: Listener(
              onPointerDown: !dis && _mode == TalkMode.hold
                  ? (_) => _vm.pressTalk()
                  : null,
              // Release is always wired in hold mode so a lift is never lost.
              onPointerUp: _mode == TalkMode.hold
                  ? (_) => _vm.releaseTalk()
                  : null,
              onPointerCancel: _mode == TalkMode.hold
                  ? (_) => _vm.releaseTalk()
                  : null,
              child: GestureDetector(
                onTap: !dis && _mode == TalkMode.keep ? _vm.tapTalk : null,
                child: Container(
                  width: 200,
                  height: 200,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _isLive ? _live : Colors.transparent,
                    border: Border.all(color: border, width: 3),
                  ),
                  child: DefaultTextStyle.merge(
                    style: TextStyle(color: fg),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.mic, size: 40, color: accent),
                        const SizedBox(height: 8),
                        Text(
                          _talkLabel(_s, _mode),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: dis ? 17 : 21,
                            height: 1.19,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.231,
                          ),
                        ),
                        if (_isLive)
                          Text(
                            _elapsed,
                            style: const TextStyle(
                              fontSize: 17,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _level(_Tokens t) => StreamBuilder<double>(
    stream: _vm.level,
    initialData: 0,
    builder: (_, snap) => _bars(t, snap.data ?? 0),
  );

  Widget _bars(_Tokens t, double level) {
    final base = _mode == TalkMode.keep
        ? const [14, 22, 34, 26, 38, 20, 30, 18, 12]
        : const [10, 16, 24, 34, 40, 30, 22, 16, 10];
    final k = (level * 4).clamp(0.0, 1.0);
    return Column(
      children: [
        SizedBox(
          height: 40,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var i = 0; i < base.length; i++) ...[
                if (i > 0) const SizedBox(width: 5),
                Container(
                  width: 6,
                  height: _isLive ? 6 + (base[i] - 6) * (0.25 + 0.75 * k) : 6,
                  decoration: BoxDecoration(
                    color: _isLive ? t.fg : t.idle,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 4),
        Text('Input level', style: TextStyle(fontSize: 14, color: t.muted)),
      ],
    );
  }
}

Widget _dot(double d, Color c) => Container(
  width: d,
  height: d,
  decoration: BoxDecoration(color: c, shape: BoxShape.circle),
);

class _Banner extends StatelessWidget {
  const _Banner({this.text = 'MIC IS LIVE', this.color = _live});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    height: 40,
    color: color,
    alignment: Alignment.center,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _dot(8, Colors.white),
        const SizedBox(width: 8),
        Text(
          text,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
        ),
      ],
    ),
  );
}
