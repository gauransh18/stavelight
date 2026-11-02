import 'package:flutter/material.dart';

import '../../core/model/pitch.dart';
import '../../core/model/score.dart';
import '../../core/model/session.dart';
import '../../core/practice/practice_engine.dart';
import '../../core/practice/suggestions.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Encouraging, non-punitive session summary. Pops with a [PracticeConfig] to practice again.
class SummaryScreen extends StatelessWidget {
  final PracticeSession session;
  final Score score;
  final PracticeConfig config;
  const SummaryScreen({super.key, required this.session, required this.score, required this.config});

  @override
  Widget build(BuildContext context) {
    final s = session;
    final t = Theme.of(context).textTheme;
    final suggestion = suggestNext(s, config, score.measures.length);
    final weak = weakestMeasures(s);
    final pitch = s.pitchAccuracy;
    final timing = s.timingAccuracy;
    final mic = s.input == InputKind.mic;
    final missedNotes = s.missedPitches.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return Scaffold(
      appBar: AppBar(title: const Text('Session summary')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(padding: const EdgeInsets.all(16), children: [
              Text(_headline(s), style: t.headlineSmall),
              const SizedBox(height: 4),
              Text(score.title, style: t.bodyMedium),
              const SizedBox(height: 16),
              LayoutBuilder(builder: (context, c) {
                // Two equal columns so the tiles always fill the row.
                final w = (c.maxWidth - 12) / 2;
                return Wrap(spacing: 12, runSpacing: 12, children: [
                  _Stat(width: w, icon: Icons.timer_outlined, label: 'Practiced', value: formatDuration(s.durationSec)),
                  _Stat(width: w, icon: Icons.view_column_outlined, label: 'Measures played', value: '${s.measuresCompleted}'),
                  if (s.input != InputKind.none && !s.lowQuality) ...[
                    _Stat(
                      width: w,
                      icon: Icons.music_note,
                      label: mic ? 'Pitch accuracy (estimate)' : 'Pitch accuracy',
                      value: pitch == null ? '—' : '${(pitch * 100).round()}%',
                    ),
                    _Stat(
                      width: w,
                      icon: Icons.av_timer,
                      label: mic ? 'On time (estimate)' : 'On time',
                      value: timing == null ? '—' : '${(timing * 100).round()}%',
                    ),
                  ],
                ]);
              }),
              if (s.input == InputKind.none)
                const Padding(padding: EdgeInsets.only(top: 12), child: InfoBanner('This session wasn’t listening, so there is nothing to score — only time practiced is recorded.')),
              if (s.lowQuality)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: InfoBanner(
                    'Most of what was heard was unclear, so accuracy isn’t shown. This is about input quality, not your playing.',
                    icon: Icons.graphic_eq,
                    color: SlColors.unsure,
                  ),
                ),
              if (!s.lowQuality && s.input != InputKind.none) ...[
                const SectionTitle('Notes'),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(children: [
                      _row(Icons.check_circle, SlColors.good, 'On time', s.correct),
                      _row(Icons.fast_rewind, SlColors.warn, 'Early', s.early),
                      _row(Icons.fast_forward, SlColors.warn, 'Late', s.late),
                      _row(Icons.swap_vert, SlColors.bad, 'Right note, wrong octave', s.octaveMismatch),
                      _row(Icons.close, SlColors.bad, 'Different note', s.wrongPitch),
                      _row(Icons.remove_circle_outline, SlColors.bad, mic ? 'Not heard' : 'Missed', s.missed),
                      _row(Icons.help_outline, SlColors.unsure, 'Unclear (not counted)', s.uncertain),
                      if (s.notAssessed > 0) _row(Icons.do_not_disturb_on_outlined, SlColors.unsure, 'Chord notes not assessed (mic)', s.notAssessed),
                      if (s.skipped > 0) _row(Icons.skip_next, SlColors.unsure, 'Skipped', s.skipped),
                      if (s.input == InputKind.midi && s.earlyReleases > 0) _row(Icons.timelapse, SlColors.warn, 'Keys released early', s.earlyReleases),
                      if (s.input == InputKind.midi && s.pedalChecks > 0) _row(Icons.keyboard_double_arrow_down, SlColors.brass, 'Pedal changes on time', s.pedalOnTime, of: s.pedalChecks),
                    ]),
                  ),
                ),
                if (s.timingSpreadMs != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'Timing consistency: notes landed within about ±${s.timingSpreadMs!.round()} ms of each other'
                      '${s.meanOffsetMs != null && s.meanOffsetMs!.abs() > 40 ? ', usually a little ${s.meanOffsetMs! < 0 ? 'early' : 'late'}' : ''}.'
                      '${mic ? ' Microphone timing is approximate.' : ''}',
                      style: t.bodyMedium,
                    ),
                  ),
                if (weak.isNotEmpty || missedNotes.isNotEmpty) const SectionTitle('Worth another look'),
                if (weak.isNotEmpty)
                  Text('Measures: ${weak.map((w) => '${w.$1 + 1} (${(w.$2 * 100).round()}%)').join(', ')}', style: t.bodyMedium),
                if (missedNotes.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('Notes: ${missedNotes.take(5).map((e) => '${Pitch.name(e.key)} ×${e.value}').join(', ')}', style: t.bodyMedium),
                  ),
              ],
              const SectionTitle('Next step'),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Icon(Icons.lightbulb_outline, color: SlColors.brass),
                      const SizedBox(width: 10),
                      Expanded(child: Text(suggestion.text, style: t.bodyLarge)),
                    ]),
                    if (suggestion.config != null) ...[
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: () => Navigator.pop(context, suggestion.config),
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('Do this now'),
                      ),
                    ],
                  ]),
                ),
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(onPressed: () => Navigator.pop(context, config), icon: const Icon(Icons.replay), label: const Text('Practice again')),
              const SizedBox(height: 8),
              TextButton(onPressed: () => Navigator.of(context).popUntil((r) => r.isFirst), child: const Text('Back to library')),
            ]),
          ),
        ),
      ),
    );
  }

  static String _headline(PracticeSession s) {
    if (s.durationSec < 30) return 'A quick run-through';
    final p = s.pitchAccuracy;
    if (s.lowQuality || p == null) return 'Time well spent';
    if (p >= 0.9) return 'Lovely playing';
    if (p >= 0.7) return 'Good progress';
    return 'Every repetition counts';
  }

  Widget _row(IconData icon, Color color, String label, int value, {int? of}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(child: Text(label)),
          Text(of == null ? '$value' : '$value of $of', style: const TextStyle(fontWeight: FontWeight.w600)),
        ]),
      );
}

class _Stat extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final double width;
  const _Stat({required this.width, required this.icon, required this.label, required this.value});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Semantics(
      label: '$label: $value',
      excludeSemantics: true,
      child: SizedBox(
        width: width,
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 8),
              Text(value, style: t.headlineMedium),
              Text(label, style: t.bodySmall),
            ]),
          ),
        ),
      ),
    );
  }
}
