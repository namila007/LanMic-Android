import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:lanmic_protocol/lanmic_protocol.dart';

import '../../../../domain/receiver_status.dart';
import '../view_models/receiver_view_model.dart';
import '../view_models/stats_line.dart';

const _bg = Color(0xFF252527);
const _muted = Color(0xFFCCCCCC);
const _green = Color(0xFF30D158);
const _grey = Color(0xFF8E8E93);
const _tabular = [FontFeature.tabularFigures()];

class ReceiverScreen extends StatefulWidget {
  const ReceiverScreen({super.key, required this.vm});

  final ReceiverViewModel vm;

  @override
  State<ReceiverScreen> createState() => _ReceiverScreenState();
}

const _blue = Color(0xFF2997FF);

class _ReceiverScreenState extends State<ReceiverScreen> {
  final _screenFocus = FocusNode();
  final _exitFocus = FocusNode();

  @override
  void dispose() {
    _screenFocus.dispose();
    _exitFocus.dispose();
    super.dispose();
  }

  // D-pad: Up/Down change Voice volume (held keys repeat), Select resets it, Left/Right move focus to and
  // from Exit. A focused Exit handles its own Select.
  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.arrowDown) {
      unawaited(widget.vm.stepVoiceVolume(k == LogicalKeyboardKey.arrowUp ? 1 : -1));
      return KeyEventResult.handled;
    }
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    if (k == LogicalKeyboardKey.arrowRight) {
      _exitFocus.requestFocus();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowLeft) {
      _screenFocus.requestFocus();
      return KeyEventResult.handled;
    }
    if ((k == LogicalKeyboardKey.select || k == LogicalKeyboardKey.enter) && !_exitFocus.hasFocus) {
      unawaited(widget.vm.resetVoiceVolume());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _screenFocus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: ListenableBuilder(
        listenable: widget.vm,
        builder: (context, _) => Scaffold(
          backgroundColor: _bg,
          body: SizedBox.expand(
            child: FittedBox(
              child: SizedBox(
                width: 1280,
                height: 720,
                child: Stack(
                  children: [
                    Positioned.fill(child: _Layout(vm: widget.vm)),
                    Positioned(
                      right: 32,
                      bottom: 32,
                      child: OutlinedButton(
                        focusNode: _exitFocus,
                        onPressed: () async {
                          try {
                            await widget.vm.exit();
                          } finally {
                            await SystemNavigator.pop();
                          }
                        },
                        style:
                            OutlinedButton.styleFrom(
                              side: const BorderSide(color: _blue),
                              shape: const StadiumBorder(),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 24,
                                vertical: 14,
                              ),
                              textStyle: GoogleFonts.inter(fontSize: 20),
                            ).copyWith(
                              // Filled when focused so the D-pad target is obvious.
                              backgroundColor: WidgetStateProperty.resolveWith(
                                (s) => s.contains(WidgetState.focused)
                                    ? _blue
                                    : null,
                              ),
                              foregroundColor: WidgetStateProperty.resolveWith(
                                (s) => s.contains(WidgetState.focused)
                                    ? Colors.white
                                    : _blue,
                              ),
                            ),
                        child: const Text('Exit'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Layout extends StatelessWidget {
  const _Layout({required this.vm});

  final ReceiverViewModel vm;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          'LAN Mic Receiver',
          style: GoogleFonts.inter(fontSize: 56, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 24),
        Container(
          width: 880,
          padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 64),
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(
            children: [
              _InfoRow('Phone address to use', vm.address),
              const SizedBox(height: 24),
              _InfoRow('PIN', vm.pin),
            ],
          ),
        ),
        const SizedBox(height: 24),
        _StatusRow(state: vm.state),
        _StatsLine(items: statsLine(vm.status)),
        _VoiceVolume(vm: vm),
        const SizedBox(height: 24),
        const Text(
          'Leave this app. It keeps running in the background.',
          style: TextStyle(fontSize: 24, color: _muted),
        ),
      ],
    );
  }
}

const _orange = Color(0xFFFF9F0A);

/// Voice volume pill + 25-step bar (-12..+12). Larger and highlighted for 2 s after a change.
class _VoiceVolume extends StatelessWidget {
  const _VoiceVolume({required this.vm});

  final ReceiverViewModel vm;

  @override
  Widget build(BuildContext context) {
    final db = vm.voiceVolumeDb, changed = vm.voiceJustChanged, limited = vm.voiceLimited;
    final fs = changed ? 40.0 : 32.0;
    final fill = limited ? _orange : _blue;
    final off = Colors.white.withValues(alpha: 0.18);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Semantics(
        label: voiceSemantics(db, limited: limited),
        excludeSemantics: true,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 96),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                height: 64,
                padding: const EdgeInsets.symmetric(horizontal: 28),
                decoration: BoxDecoration(
                  color: changed ? const Color(0x332997FF) : Colors.transparent,
                  borderRadius: BorderRadius.circular(32),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Voice volume',
                      style: TextStyle(fontSize: fs, color: changed ? Colors.white : _muted, fontFeatures: _tabular),
                    ),
                    const SizedBox(width: 16),
                    Text(
                      dbText(db),
                      style: TextStyle(
                        fontSize: fs,
                        fontWeight: FontWeight.w600,
                        color: changed ? _blue : Colors.white,
                        fontFeatures: _tabular,
                      ),
                    ),
                    if (limited) ...[
                      const SizedBox(width: 16),
                      Container(
                        width: 14,
                        height: 14,
                        decoration: const BoxDecoration(color: _orange, shape: BoxShape.circle),
                      ),
                      const SizedBox(width: 10),
                      const Text('Voice limited', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w600)),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                height: 24,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    for (var i = 0; i < 25; i++) ...[
                      if (i > 0) const SizedBox(width: 4),
                      Container(
                        key: Key('voice-step-${i - 12}'),
                        width: 14,
                        height: i == 12 ? 24 : 14,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(3),
                          color: _stepOn(i - 12, db)
                              ? (i == 12 ? Colors.white : fill)
                              : off,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // The centre step is always lit (white); steps between it and the value are filled.
  static bool _stepOn(int d, int db) => d == 0 || (db > 0 ? d > 0 && d <= db : d < 0 && d >= db);
}

class _StatsLine extends StatelessWidget {
  const _StatsLine({required this.items});

  final List<StatItem> items;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    const base = TextStyle(fontSize: 32, height: 1.19, fontFeatures: _tabular);
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Semantics(
        label: statsSemantics(items),
        excludeSemantics: true,
        child: Wrap(
          spacing: 40,
          runSpacing: 8,
          alignment: WrapAlignment.center,
          children: [
            for (final (label, value, q) in items)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(label, style: base.copyWith(color: _muted)),
                  const SizedBox(width: 12),
                  Text(value, style: base.copyWith(fontWeight: FontWeight.w600)),
                  if (q != null) ...[
                    const SizedBox(width: 12),
                    Container(
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: switch (q) {
                          Quality.good => _green,
                          Quality.ok => const Color(0xFFFF9F0A),
                          Quality.slow => const Color(0xFFFF453A),
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      qualityLabel(q),
                      style: base.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ],
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [
      Text(label, style: const TextStyle(fontSize: 28, color: _muted)),
      // scaleDown only kicks in with wide fallback fonts (tests).
      Flexible(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            value,
            style: GoogleFonts.inter(
              fontSize: 56,
              fontWeight: FontWeight.w600,
              fontFeatures: _tabular,
            ),
          ),
        ),
      ),
    ],
  );
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.state});

  final TvState state;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 20,
        height: 20,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: state == TvState.listening ? _grey : _green,
        ),
      ),
      const SizedBox(width: 16),
      Text(
        state.label,
        style: GoogleFonts.inter(fontSize: 40, fontWeight: FontWeight.w600),
      ),
      if (state == TvState.receiving) ...[
        const SizedBox(width: 20),
        const _Eq(key: Key('eq')),
      ],
    ],
  );
}

class _Eq extends StatefulWidget {
  const _Eq({super.key});

  @override
  State<_Eq> createState() => _EqState();
}

class _EqState extends State<_Eq> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  // Stagger each bar by 0.15s (0.15 of the 1s cycle), scaleY 0.3..1.
  double _scale(int i) {
    final t = (_c.value + i * 0.15) % 1.0;
    return 0.3 + 0.7 * (t < 0.5 ? t * 2 : (1 - t) * 2);
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _c,
    builder: (_, _) => Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        for (var i = 0; i < 5; i++)
          Padding(
            padding: EdgeInsets.only(left: i == 0 ? 0 : 6),
            child: Container(
              width: 8,
              height: 36 * _scale(i),
              decoration: BoxDecoration(
                color: _green,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
      ],
    ),
  );
}
