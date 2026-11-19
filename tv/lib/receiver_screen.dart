import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

enum TvState {
  listening('Listening'),
  connected('Phone connected'),
  receiving('Receiving audio');

  const TvState(this.label);
  final String label;
}

const _bg = Color(0xFF252527);
const _muted = Color(0xFFCCCCCC);
const _green = Color(0xFF30D158);
const _grey = Color(0xFF8E8E93);
const _tabular = [FontFeature.tabularFigures()];

class ReceiverScreen extends StatefulWidget {
  const ReceiverScreen({super.key, this.initialState = TvState.listening});

  final TvState initialState;

  @override
  State<ReceiverScreen> createState() => _ReceiverScreenState();
}

const _blue = Color(0xFF2997FF);

class _ReceiverScreenState extends State<ReceiverScreen> {
  late TvState _state = widget.initialState;
  final _screenFocus = FocusNode();
  final _exitFocus = FocusNode();

  @override
  void dispose() {
    _screenFocus.dispose();
    _exitFocus.dispose();
    super.dispose();
  }

  // D-pad down/right moves to Exit, up/left back to the screen.
  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.arrowDown ||
        k == LogicalKeyboardKey.arrowRight) {
      _exitFocus.requestFocus();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.arrowLeft) {
      _screenFocus.requestFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // Fake transition so every state is reachable until networking exists.
  void _cycle() => setState(
    () => _state = TvState.values[(_state.index + 1) % TvState.values.length],
  );

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
      },
      child: Actions(
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              _cycle();
              return null;
            },
          ),
        },
        child: Focus(
          focusNode: _screenFocus,
          autofocus: true,
          onKeyEvent: _onKey,
          child: GestureDetector(
            onTap: _cycle,
            child: Scaffold(
              backgroundColor: _bg,
              body: SizedBox.expand(
                child: FittedBox(
                  child: SizedBox(
                    width: 1280,
                    height: 720,
                    child: Stack(
                      children: [
                        Positioned.fill(child: _Layout(state: _state)),
                        Positioned(
                          right: 32,
                          bottom: 32,
                          child: OutlinedButton(
                            focusNode: _exitFocus,
                            onPressed: SystemNavigator.pop,
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
                                  backgroundColor:
                                      WidgetStateProperty.resolveWith(
                                        (s) => s.contains(WidgetState.focused)
                                            ? _blue
                                            : null,
                                      ),
                                  foregroundColor:
                                      WidgetStateProperty.resolveWith(
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
        ),
      ),
    );
  }
}

class _Layout extends StatelessWidget {
  const _Layout({required this.state});

  final TvState state;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          'LAN Mic Receiver',
          style: GoogleFonts.inter(fontSize: 56, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 40),
        Container(
          width: 880,
          padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 64),
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.circular(18),
          ),
          child: const Column(
            children: [
              _InfoRow('Phone address to use', '192.168.1.42'),
              SizedBox(height: 24),
              _InfoRow('PIN', '482917'),
            ],
          ),
        ),
        const SizedBox(height: 40),
        _StatusRow(state: state),
        const SizedBox(height: 40),
        const Text(
          'Leave this app. It keeps running in the background.',
          style: TextStyle(fontSize: 24, color: _muted),
        ),
      ],
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
        const _Eq(),
      ],
    ],
  );
}

class _Eq extends StatefulWidget {
  const _Eq();

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
