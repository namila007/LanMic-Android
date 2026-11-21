import 'package:flutter/material.dart';
import 'package:lanmic/ui/features/mic/view_models/stats_text.dart';

const _orange = Color(0xFFFF9F0A);

/// "Mic boost" slider (-12..+12 dB, tick at 0). Double-tapping the value resets it; while the limiter
/// works a hint with a dot and text says so (never colour alone).
class MicBoostRow extends StatelessWidget {
  const MicBoostRow({
    super.key,
    required this.db,
    required this.limiting,
    required this.onChanged,
    required this.fg,
    required this.muted,
    required this.accent,
  });

  final int db;
  final bool limiting;
  final ValueChanged<int> onChanged;
  final Color fg, muted, accent;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      ConstrainedBox(
        constraints: const BoxConstraints(
          minHeight: 48,
        ), // grows with large text
        child: Row(
          children: [
            ConstrainedBox(
              // Sized by its text (no fixed width), capped so a huge font wraps instead of squeezing the slider.
              constraints: const BoxConstraints(maxWidth: 120),
              child: Text(
                'Mic boost',
                style: TextStyle(fontSize: 14, color: muted),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 3,
              child: SizedBox(
                height:
                    48, // the slider's own touch height; only the text scales
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Container(
                      key: const ValueKey('boost-tick'),
                      width: 2,
                      height: 16,
                      decoration: BoxDecoration(
                        color: const Color(0xFF7A7A7A),
                        borderRadius: BorderRadius.circular(1),
                      ),
                    ),
                    Semantics(
                      label: 'Mic boost',
                      child: Slider(
                        key: const ValueKey('boost-slider'),
                        min: -12,
                        max: 12,
                        divisions: 24,
                        value: db.toDouble(),
                        activeColor: accent,
                        semanticFormatterCallback: (v) => dbSpoken(v.round()),
                        onChanged: (v) => onChanged(v.round()),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 12),
            Semantics(
              button: true,
              label: 'Mic boost ${dbText(db)}. Double tap to reset to 0 dB.',
              excludeSemantics: true,
              onTap: () => onChanged(0),
              child: GestureDetector(
                key: const ValueKey('boost-value'),
                behavior: HitTestBehavior.opaque,
                onDoubleTap: () => onChanged(0),
                child: Container(
                  constraints: const BoxConstraints(
                    minWidth: 60,
                    minHeight: 44,
                  ),
                  alignment: Alignment.centerRight,
                  child: Text(
                    dbText(db),
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      color: fg,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      if (limiting)
        Semantics(
          liveRegion: true,
          child: Padding(
            padding: const EdgeInsets.only(left: 80),
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(
                    color: _orange,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                const Text(
                  'Too loud, limiting',
                  style: TextStyle(fontSize: 14),
                ),
              ],
            ),
          ),
        ),
    ],
  );
}
