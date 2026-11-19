import 'dart:async';

import 'package:flutter/material.dart';

enum PhoneState { connect, wrongPin, ready, liveHold, liveKeep, lost }

enum TalkMode { hold, keep }

const _live = Color(0xFFD92D20);
const _ring = Color(0xFFFF453A);
const _blue = Color(0xFF0066CC);
const _disabled = Color(0xFF7A7A7A);

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
  PhoneState.connect: Color(0xFF8E8E93),
  PhoneState.wrongPin: Color(0xFFFF453A),
  PhoneState.ready: Color(0xFF30D158),
  PhoneState.liveHold: Color(0xFF30D158),
  PhoneState.liveKeep: Color(0xFF30D158),
  PhoneState.lost: Color(0xFFFF9F0A),
};

String chipLabel(PhoneState s) => switch (s) {
  PhoneState.connect => 'Not connected',
  PhoneState.wrongPin => 'Wrong PIN',
  PhoneState.lost => 'Connection lost. Retrying…',
  _ => 'Connected · Living Room',
};

String _talkLabel(PhoneState s) => switch (s) {
  PhoneState.connect || PhoneState.wrongPin => 'Connect first',
  PhoneState.ready => 'HOLD TO TALK',
  PhoneState.liveHold => 'TALKING…',
  PhoneState.liveKeep => 'LIVE · TAP TO STOP',
  PhoneState.lost => 'Reconnecting…',
};

class MicScreen extends StatefulWidget {
  const MicScreen({super.key, this.initialState = PhoneState.connect});

  /// Test seam: start in any state.
  final PhoneState initialState;

  @override
  State<MicScreen> createState() => _MicScreenState();
}

class _MicScreenState extends State<MicScreen>
    with SingleTickerProviderStateMixin {
  late PhoneState _s = widget.initialState;
  late TalkMode _mode = _s == PhoneState.liveKeep
      ? TalkMode.keep
      : TalkMode.hold;
  late final _pin = TextEditingController(
    text: _s == PhoneState.wrongPin ? '000000' : '',
  );
  final _addr = TextEditingController(text: '192.168.1.42');
  late final _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );

  // Elapsed live time; restarts each time the mic goes live.
  int _seconds = 0;
  Timer? _tick;

  bool get _isLive => _s == PhoneState.liveHold || _s == PhoneState.liveKeep;
  bool get _connected =>
      _s == PhoneState.ready || _isLive || _s == PhoneState.lost;
  bool get _talkDisabled => !_connected || _s == PhoneState.lost;

  @override
  void initState() {
    super.initState();
    if (_isLive) _startClock();
  }

  void _startClock() {
    _pulse.repeat();
    _seconds = 0;
    _tick = Timer.periodic(
      const Duration(seconds: 1),
      (_) => setState(() => _seconds++),
    );
  }

  void _stopClock() {
    _pulse.stop();
    _tick?.cancel();
    _tick = null;
  }

  String get _elapsed {
    return '${_seconds ~/ 60}:${(_seconds % 60).toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _tick?.cancel();
    _pulse.dispose();
    _pin.dispose();
    _addr.dispose();
    super.dispose();
  }

  void _set(PhoneState s) {
    final wasLive = _isLive;
    setState(() => _s = s);
    if (_isLive && !wasLive) _startClock();
    if (!_isLive && wasLive) _stopClock();
  }

  void _connectTap() =>
      _set(_pin.text == '000000' ? PhoneState.wrongPin : PhoneState.ready);

  void _setMode(TalkMode m) {
    _mode = m;
    _set(_isLive ? PhoneState.ready : _s);
  }

  @override
  Widget build(BuildContext context) {
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
            if (_s == PhoneState.liveKeep) const _Banner(),
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
                          ],
                          const SizedBox(height: 20),
                          _segments(t),
                          const Spacer(),
                          Center(child: _talk(t)),
                          const SizedBox(height: 12),
                          _level(t),
                          const Spacer(),
                          if (_connected)
                            Center(
                              child: OutlinedButton(
                                onPressed: () => _set(PhoneState.connect),
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

  Widget _chip(_Tokens t) => GestureDetector(
    // Debug: long-press the chip to force the `lost` state.
    onLongPress: () => _set(PhoneState.lost),
    child: Container(
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
          Text(chipLabel(_s), style: const TextStyle(fontSize: 14)),
        ],
      ),
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
        _field(t, 'TV address', _addr, 17, 0, TextInputType.number),
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
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _connectTap,
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
              onTap: () => _setMode(m),
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
                  ? (_) => _set(PhoneState.liveHold)
                  : null,
              onPointerUp: !dis && _mode == TalkMode.hold
                  ? (_) => _set(PhoneState.ready)
                  : null,
              onPointerCancel: !dis && _mode == TalkMode.hold
                  ? (_) => _set(PhoneState.ready)
                  : null,
              child: GestureDetector(
                onTap: !dis && _mode == TalkMode.keep
                    ? () =>
                          _set(_isLive ? PhoneState.ready : PhoneState.liveKeep)
                    : null,
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
                          _talkLabel(_s),
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

  Widget _level(_Tokens t) {
    final base = _s == PhoneState.liveKeep
        ? const [14, 22, 34, 26, 38, 20, 30, 18, 12]
        : const [10, 16, 24, 34, 40, 30, 22, 16, 10];
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
                  height: _isLive ? base[i].toDouble() : 6,
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
  const _Banner();

  @override
  Widget build(BuildContext context) => Container(
    height: 40,
    color: _live,
    alignment: Alignment.center,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _dot(8, Colors.white),
        const SizedBox(width: 8),
        const Text(
          'MIC IS LIVE',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
        ),
      ],
    ),
  );
}
