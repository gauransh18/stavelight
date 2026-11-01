import 'package:flutter/material.dart';

import '../../core/model/score.dart';
import '../theme.dart';

/// Short contextual explanations for notation and practice controls.
const helpTopics = <String, (String, String)>{
  'wait': ('Wait Mode', 'The music pauses on each note or chord until you play it. If you get stuck, a Skip button appears after a few seconds so you can move on.'),
  'follow': ('Follow Along', 'The music moves at the tempo you choose and Stavelight tells you whether each note was on time, early, late or a different pitch.'),
  'tempo': ('Tempo', 'Practice slowly first. 100% is the tempo written in the score. Timing feedback is scaled, so playing at 60% is judged just as fairly.'),
  'hands': ('Hands separately', 'Practice one hand while Stavelight plays the other softly (you can turn that off). Notes for the hand you are not practicing appear as outlines.'),
  'loop': ('Section practice', 'Pick a range of measures to repeat. A short count-in plays before each repetition if enabled.'),
  'transpose': ('Transpose', 'Shift the expected notes and playback up or down by semitones. The score itself is not changed and the current shift is always shown.'),
  'pedal': ('Sustain pedal', 'The pedal lane shows when the sustain pedal should go down (Ped.) and come up (✱). It is separate from how long you hold each key: a note can keep sounding after you lift your finger if the pedal is down. Dashed marks are unverified.'),
  'duration': ('Note length', 'A note’s written length (including dots and ties) tells you how long to hold the key. Long bars in the falling view show the key-hold. The faint tail after a bar is sound continuing because of the pedal — you don’t need to keep holding the key for that part.'),
  'confidence': ('Recognized vs verified', 'Notes read from a scan or photo are “recognized”: the app is guessing. Low-confidence notes are marked with a question badge. Once you check or edit a note it becomes “verified”. Practice feedback is only as good as the score.'),
  'mic': ('Microphone limits', 'The microphone hears one main pitch at a time. Chords, heavy pedal, room noise and very low notes make detection harder. When unsure, Stavelight says so instead of marking a mistake. A MIDI keyboard gives precise results.'),
  'midi': ('MIDI keyboards', 'Connect a digital piano by USB (an OTG adapter on Android) or Bluetooth MIDI. MIDI reports exactly which key you pressed and released, and the sustain pedal.'),
  'octave': ('Octave check', 'Pitch detectors sometimes hear a note one octave too high or low. Calibration lets you correct this so a right note is never judged as the wrong octave.'),
  'keysig': ('Key signature', 'Sharps or flats at the start of each line apply to every matching note unless an accidental says otherwise.'),
  'timesig': ('Time signature', 'The top number is beats per measure; the bottom is which note gets one beat (4 = quarter note, 8 = eighth note).'),
};

class HelpButton extends StatelessWidget {
  final String topic;
  final double size;
  const HelpButton(this.topic, {super.key, this.size = 20});

  @override
  Widget build(BuildContext context) {
    final t = helpTopics[topic];
    if (t == null) return const SizedBox.shrink();
    return IconButton(
      tooltip: 'About ${t.$1}',
      iconSize: size,
      icon: const Icon(Icons.info_outline),
      onPressed: () => showHelp(context, topic),
    );
  }
}

void showHelp(BuildContext context, String topic) {
  final t = helpTopics[topic];
  if (t == null) return;
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (c) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t.$1, style: Theme.of(c).textTheme.titleLarge),
          const SizedBox(height: 12),
          Text(t.$2, style: Theme.of(c).textTheme.bodyLarge),
        ]),
      ),
    ),
  );
}

/// Badge for a hand: color + letter so it never relies on color alone.
class HandBadge extends StatelessWidget {
  final Hand hand;
  final double size;
  const HandBadge(this.hand, {super.key, this.size = 22});

  @override
  Widget build(BuildContext context) {
    final c = SlColors.hand(hand, Theme.of(context).brightness);
    final label = switch (hand) { Hand.right => 'R', Hand.left => 'L', Hand.unassigned => '?' };
    return Semantics(
      label: switch (hand) { Hand.right => 'Right hand', Hand.left => 'Left hand', Hand.unassigned => 'Hand not assigned' },
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: c,
          shape: hand == Hand.left ? BoxShape.rectangle : BoxShape.circle,
          borderRadius: hand == Hand.left ? BorderRadius.circular(5) : null,
        ),
        child: Text(label, style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: size * 0.55)),
      ),
    );
  }
}

/// "Recognized 63%" / "Verified" label with icon.
class ConfidenceChip extends StatelessWidget {
  final double confidence;
  final bool verified;
  const ConfidenceChip({super.key, required this.confidence, required this.verified});

  @override
  Widget build(BuildContext context) {
    final (icon, color, text) = verified
        ? (Icons.verified, SlColors.good, 'Verified')
        : confidence >= 0.75
            ? (Icons.check_circle_outline, SlColors.seed, 'Recognized ${(confidence * 100).round()}%')
            : (Icons.help_outline, SlColors.warn, 'Uncertain ${(confidence * 100).round()}%');
    return Chip(
      avatar: Icon(icon, size: 18, color: color),
      label: Text(text),
      visualDensity: VisualDensity.compact,
    );
  }
}

class SectionTitle extends StatelessWidget {
  final String text;
  final Widget? trailing;
  const SectionTitle(this.text, {super.key, this.trailing});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
        child: Row(children: [
          Expanded(child: Text(text, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600))),
          ?trailing,
        ]),
      );
}

/// Informational banner (warning/info/error) used for import issues and limitations.
class InfoBanner extends StatelessWidget {
  final String text;
  final IconData icon;
  final Color? color;
  final Widget? action;
  const InfoBanner(this.text, {super.key, this.icon = Icons.info_outline, this.color, this.action});

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(14), border: Border.all(color: c.withValues(alpha: 0.35))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, color: c),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: Theme.of(context).textTheme.bodyMedium)),
        if (action != null) ...[const SizedBox(width: 8), action!],
      ]),
    );
  }
}

String formatDuration(int seconds) {
  if (seconds < 60) return '${seconds}s';
  final m = seconds ~/ 60;
  if (m < 60) return '$m min';
  return '${m ~/ 60} h ${m % 60} min';
}

String formatDate(DateTime d) {
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${d.day} ${months[d.month - 1]} ${d.year}';
}
