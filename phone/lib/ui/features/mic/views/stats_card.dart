import 'package:flutter/material.dart';
import 'package:lanmic/domain/link_stats.dart';
import 'package:lanmic/ui/features/mic/view_models/stats_text.dart';
import 'package:lanmic_protocol/lanmic_protocol.dart';

const _dots = {
  Quality.good: Color(0xFF30D158),
  Quality.ok: Color(0xFFFF9F0A),
  Quality.slow: Color(0xFFFF453A),
};
const _tabular = [FontFeature.tabularFigures()];

/// Delay, network and lost audio, with a collapsible grid of where the time goes.
class StatsCard extends StatelessWidget {
  const StatsCard({
    super.key,
    required this.link,
    required this.phoneBand,
    required this.detailsOpen,
    this.lost = false,
    required this.onToggle,
    required this.fg,
    required this.muted,
    required this.card,
    required this.accent,
  });

  final LinkSnapshot link;
  final WifiBand phoneBand;
  final bool detailsOpen;

  /// Connection lost: the numbers are stale, so show dashes.
  final bool lost;
  final VoidCallback onToggle;
  final Color fg, muted, card, accent;

  String get _delayText {
    if (lost) return '—';
    if (link.rttMs == null) return 'Measuring…';
    if (link.tvTooOld) return 'Update the TV app to see the full delay';
    if (link.tvMs == null) return 'Talk to measure';
    return aboutMs(link.delayMs!);
  }

  @override
  Widget build(BuildContext context) {
    final q = lost ? null : link.quality;
    final delayKnown = !lost && link.delayMs != null;
    final lostPm = lost ? null : link.lostPermille;
    final summary = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text('Delay', style: TextStyle(fontSize: 14, color: muted)),
            const SizedBox(width: 12),
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  _delayText,
                  maxLines: 1,
                  softWrap: false,
                  style: TextStyle(
                    fontSize: delayKnown ? 20 : 17,
                    fontWeight: FontWeight.w600,
                    fontFeatures: _tabular,
                    color: delayKnown ? fg : muted,
                  ),
                ),
              ),
            ),
            if (q != null) ...[
              const SizedBox(width: 12),
              const Spacer(),
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: _dots[q], shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
              Text(
                qualityLabel(q),
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: fg),
              ),
            ],
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 32,
          children: [
            _pair('Network', lost || link.rttMs == null ? null : ms(link.rttMs!)),
            _pair('Lost audio', lostPm == null ? null : percent(lostPm)),
          ],
        ),
      ],
    );
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
      decoration: BoxDecoration(color: card, borderRadius: BorderRadius.circular(18)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            container: true,
            label: delayKnown ? statsSemantics(link) : null,
            excludeSemantics: delayKnown,
            child: summary,
          ),
          if (detailsOpen) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.only(top: 12),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: fg.withValues(alpha: 0.12))),
              ),
              child: _grid(),
            ),
          ],
          Semantics(
            label: 'Details',
            expanded: detailsOpen,
            button: true,
            excludeSemantics: true,
            child: TextButton(
              onPressed: onToggle,
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 44),
                alignment: Alignment.centerLeft,
                padding: EdgeInsets.zero,
                foregroundColor: accent,
              ),
              child: ExcludeSemantics(
                child: Text(
                  '${detailsOpen ? '▾' : '▸'} Details',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: accent),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _pair(String label, String? value) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(label, style: TextStyle(fontSize: 14, color: muted)),
      const SizedBox(width: 8),
      Text(
        value ?? '—',
        style: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          fontFeatures: _tabular,
          color: value == null ? muted : fg,
        ),
      ),
    ],
  );

  Widget _cell(String label, String? value) => Expanded(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontSize: 14, color: muted)),
        Text(
          value ?? '—',
          style: TextStyle(fontSize: 17, fontFeatures: _tabular, color: value == null ? muted : fg),
        ),
      ],
    ),
  );

  Widget _grid() {
    String? tilde(int? v) => v == null ? null : tildeMs(v);
    return Column(
      children: [
        Row(
          children: [
            _cell('Phone', tildeMs(link.phoneMs)),
            _cell('Wi-Fi', tilde(link.wifiMs)),
            _cell('TV', tilde(link.tvMs)),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            _cell('Jitter', link.jitterMs == null ? null : ms(link.jitterMs!)),
            _cell('Phone Wi-Fi', bandLabel(phoneBand)),
            _cell('TV Wi-Fi', bandLabel(link.tvBand)),
          ],
        ),
      ],
    );
  }
}
