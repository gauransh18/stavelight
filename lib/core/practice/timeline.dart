import '../model/score.dart';
import '../model/session.dart';

/// A key press the player is expected to make. Tie continuations are folded into the first note.
class ExpectedNote {
  final String noteId;

  /// Expected MIDI after practice transposition.
  final int midi;
  final int writtenMidi;
  final Hand hand;
  final int startTick;
  final int holdTicks;
  final double start; // score seconds at 100% tempo
  final double holdSec;
  final double soundEnd; // with pedal, display only
  final int measure;
  final int? finger;
  final double confidence;
  final bool verified;

  /// False when the note belongs to the hand that is not being practiced.
  final bool active;

  ExpectedNote({
    required this.noteId,
    required this.midi,
    required this.writtenMidi,
    required this.hand,
    required this.startTick,
    required this.holdTicks,
    required this.start,
    required this.holdSec,
    required this.soundEnd,
    required this.measure,
    required this.finger,
    required this.confidence,
    required this.verified,
    required this.active,
  });

  double get end => start + holdSec;
}

class ExpectedChord {
  final int index;
  final int startTick;
  final double start;
  final int measure;
  final List<ExpectedNote> notes;
  ExpectedChord(this.index, this.startTick, this.start, this.measure, this.notes);
}

class TimelinePedal {
  final double time;
  final bool down;
  final bool certain;
  TimelinePedal(this.time, this.down, this.certain);
}

class Beat {
  final double time;
  final bool downbeat;
  final int measure;
  final int beatInMeasure;
  Beat(this.time, this.downbeat, this.measure, this.beatInMeasure);
}

/// Flattened, time-resolved view of a score for practice.
class PracticeTimeline {
  final Score score;
  final TempoMap tempoMap;
  final int transpose;
  final HandsSelection hands;
  final List<ExpectedNote> notes; // all, sorted by start
  final List<ExpectedChord> chords; // active notes only
  final List<TimelinePedal> pedals;
  final List<Beat> beats;
  final List<double> measureStarts;
  final double duration;

  PracticeTimeline._(this.score, this.tempoMap, this.transpose, this.hands, this.notes, this.chords, this.pedals,
      this.beats, this.measureStarts, this.duration);

  /// Notes within this many ticks of each other start the same chord (about a 64th at 480 PPQ).
  static const chordTolerance = 30;

  factory PracticeTimeline.build(Score score, {int transpose = 0, HandsSelection hands = HandsSelection.both}) {
    final map = score.tempoMap;
    bool isActive(Hand h) => switch (hands) {
          HandsSelection.both => true,
          HandsSelection.right => h != Hand.left,
          HandsSelection.left => h == Hand.left,
        };

    final sorted = [...score.notes]..sort((a, b) => a.startTick.compareTo(b.startTick));
    final notes = <ExpectedNote>[];
    for (final n in sorted) {
      if (n.tieStop) continue; // continuation of a tie: key stays down, no new press
      final midi = (n.midi + transpose).clamp(0, 127);
      final start = map.secondsAt(n.startTick);
      final holdEnd = map.secondsAt(n.startTick + n.effectiveHoldTicks);
      notes.add(ExpectedNote(
        noteId: n.id,
        midi: midi,
        writtenMidi: n.midi,
        hand: n.hand,
        startTick: n.startTick,
        holdTicks: n.effectiveHoldTicks,
        start: start,
        holdSec: holdEnd - start,
        soundEnd: map.secondsAt(score.soundingEndTick(n)),
        measure: n.measureIndex,
        finger: n.finger,
        confidence: n.confidence,
        verified: n.verified,
        active: isActive(n.hand),
      ));
    }

    final chords = <ExpectedChord>[];
    for (final n in notes.where((n) => n.active)) {
      if (chords.isNotEmpty && n.startTick - chords.last.startTick <= chordTolerance) {
        chords.last.notes.add(n);
      } else {
        chords.add(ExpectedChord(chords.length, n.startTick, n.start, n.measure, [n]));
      }
    }

    final pedals = [
      for (final p in score.pedals)
        TimelinePedal(map.secondsAt(p.tick), p.type == PedalType.down, p.verified || p.confidence >= 0.75),
    ];

    final beats = <Beat>[];
    final measureStarts = <double>[];
    for (final m in score.measures) {
      measureStarts.add(map.secondsAt(m.startTick));
      final bt = m.time.beatTicks(kPpq);
      var i = 0;
      for (var t = m.startTick; t < m.endTick; t += bt) {
        beats.add(Beat(map.secondsAt(t), i == 0, m.index, i));
        i++;
      }
    }
    final endTick = score.endTick;
    return PracticeTimeline._(score, map, transpose, hands, notes, chords, pedals, beats, measureStarts,
        map.secondsAt(endTick));
  }

  int get measureCount => measureStarts.length;

  double measureStart(int i) {
    if (measureStarts.isEmpty) return 0;
    if (i >= measureStarts.length) return duration;
    return measureStarts[i.clamp(0, measureStarts.length - 1)];
  }

  double measureEnd(int i) => i + 1 >= measureStarts.length ? duration : measureStarts[i + 1];

  int measureAt(double t) {
    var lo = 0, hi = measureStarts.length - 1;
    if (hi < 0) return 0;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (measureStarts[mid] <= t + 1e-9) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  /// Seconds per beat (score time) at time [t], used for count-in.
  double beatLengthAt(double t) {
    final m = score.measures.isEmpty ? null : score.measures[measureAt(t)];
    final bt = m?.time.beatTicks(kPpq) ?? kPpq;
    final tick = tempoMap.tickAt(t).round();
    return tempoMap.secondsAt(tick + bt) - tempoMap.secondsAt(tick);
  }

  int beatsPerMeasureAt(double t) {
    if (score.measures.isEmpty) return 4;
    return score.measures[measureAt(t)].time.beatsPerMeasure(kPpq);
  }
}
