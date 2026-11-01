import '../model/session.dart';
import 'practice_engine.dart';

class PracticeSuggestion {
  final String text;

  /// Ready-to-use settings for the suggested next step, or null when the advice is not a practice run.
  final PracticeConfig? config;
  const PracticeSuggestion(this.text, [this.config]);
}

/// Measures with the lowest reliable accuracy, worst first.
List<(int, double)> weakestMeasures(PracticeSession s, {int limit = 3}) {
  final list = <(int, double)>[];
  s.perMeasure.forEach((m, st) {
    final a = st.accuracy;
    if (a != null && st.expected - st.uncertain >= 2 && a < 0.85) list.add((m, a));
  });
  list.sort((a, b) => a.$2.compareTo(b.$2));
  return list.take(limit).toList();
}

PracticeConfig _copy(PracticeConfig c) => PracticeConfig(
      mode: c.mode,
      hands: c.hands,
      tempoFactor: c.tempoFactor,
      transpose: c.transpose,
      metronome: c.metronome,
      accentDownbeat: c.accentDownbeat,
      countInBeats: c.countInBeats,
      loop: c.loop,
      loopStart: c.loopStart,
      loopEnd: c.loopEnd,
      countInEachLoop: c.countInEachLoop,
      playOtherHand: c.playOtherHand,
      waitTimeout: c.waitTimeout,
      autoSkip: c.autoSkip,
    );

/// One encouraging, concrete next step. Never draws conclusions from low-quality input.
PracticeSuggestion suggestNext(PracticeSession s, PracticeConfig last, int measureCount) {
  if (s.input == InputKind.none) {
    return PracticeSuggestion('Turn on listening (MIDI or microphone) next time to get feedback on your playing.', _copy(last));
  }
  if (s.lowQuality) {
    return const PracticeSuggestion(
        'Much of what was heard was unclear, so accuracy can’t be judged fairly. Try a quieter room, recalibrate the microphone, or connect a MIDI keyboard.');
  }
  if (s.assessed < 3) {
    return PracticeSuggestion('Play a little longer to get useful feedback.', _copy(last));
  }
  final weak = weakestMeasures(s);
  final pitch = s.pitchAccuracy ?? 0;
  if (weak.isNotEmpty) {
    final worst = weak.first;
    final start = worst.$1;
    final end = (start + 1).clamp(0, measureCount - 1);
    final slower = worst.$2 < 0.6;
    final tempo = slower ? (last.tempoFactor * 0.8).clamp(0.4, 1.5) : last.tempoFactor;
    final c = _copy(last)
      ..loop = true
      ..loopStart = start
      ..loopEnd = end
      ..tempoFactor = tempo
      ..countInBeats = last.countInBeats == 0 ? 2 : last.countInBeats
      ..countInEachLoop = true;
    if (slower && last.mode == PracticeMode.follow) c.mode = PracticeMode.wait;
    final range = start == end ? 'measure ${start + 1}' : 'measures ${start + 1}–${end + 1}';
    final how = slower ? ' at ${(tempo * 100).round()}%${c.mode == PracticeMode.wait ? ' in Wait mode' : ''}' : '';
    return PracticeSuggestion('Loop $range$how a few times — that’s where the most notes slipped.', c);
  }
  final timing = s.timingAccuracy;
  if (pitch >= 0.9 && timing != null && timing < 0.7 && s.input == InputKind.midi || pitch >= 0.9 && timing != null && timing < 0.6) {
    final c = _copy(last)
      ..metronome = true
      ..tempoFactor = (last.tempoFactor * 0.85).clamp(0.4, 1.5)
      ..mode = PracticeMode.follow;
    return PracticeSuggestion('The notes are right. Now focus on steady timing: keep the metronome on at ${(c.tempoFactor * 100).round()}%.', c);
  }
  if (last.mode == PracticeMode.wait && pitch >= 0.9) {
    return PracticeSuggestion('Great accuracy. Try Follow along so the music keeps moving.', _copy(last)..mode = PracticeMode.follow);
  }
  if (last.tempoFactor < 1 && pitch >= 0.9) {
    final next = (last.tempoFactor + 0.1).clamp(0.25, 1.0);
    return PracticeSuggestion('Nice work. Nudge the tempo up to ${(next * 100).round()}%.', _copy(last)..tempoFactor = next);
  }
  if (last.hands != HandsSelection.both && pitch >= 0.9) {
    return PracticeSuggestion('This hand is solid. Try both hands together, slowly.',
        _copy(last)
          ..hands = HandsSelection.both
          ..tempoFactor = (last.tempoFactor * 0.8).clamp(0.4, 1.0));
  }
  return PracticeSuggestion('Keep going — play it through once more, or pick a new section.', _copy(last));
}
