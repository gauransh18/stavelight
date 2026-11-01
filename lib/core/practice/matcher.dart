import 'dart:math' as math;

import '../model/pitch.dart';
import '../model/session.dart';
import 'input_event.dart';
import 'timeline.dart';

enum NoteOutcome { pending, correct, early, late, wrongPitch, octaveMismatch, missed, uncertain, skipped, notAssessed }

enum FeedbackKind { correct, early, late, wrong, octaveHigh, octaveLow, extra, uncertain, noisy, releasedEarly, notHeard }

/// Short, transient message for the practice screen.
class PracticeFeedback {
  final FeedbackKind kind;
  final double time;
  final int? midi;
  final String? noteId;
  const PracticeFeedback(this.kind, this.time, {this.midi, this.noteId});

  String get label => switch (kind) {
        FeedbackKind.correct => 'Correct',
        FeedbackKind.early => 'Early',
        FeedbackKind.late => 'Late',
        FeedbackKind.wrong => 'Try again',
        FeedbackKind.octaveHigh => 'Octave too high',
        FeedbackKind.octaveLow => 'Octave too low',
        FeedbackKind.extra => 'Extra note',
        FeedbackKind.uncertain => 'Not sure what was played',
        FeedbackKind.noisy => 'Input too noisy',
        FeedbackKind.releasedEarly => 'Released early',
        FeedbackKind.notHeard => 'Not heard',
      };

  /// True for outcomes that should never be presented as an error.
  bool get isNeutral => kind == FeedbackKind.uncertain || kind == FeedbackKind.noisy;
  bool get isPositive => kind == FeedbackKind.correct;
}

class NoteResult {
  final ExpectedNote note;
  NoteOutcome outcome = NoteOutcome.pending;

  /// Real-time offset in seconds (negative = early). Set for correct/early/late.
  double? offset;
  int? playedMidi;
  double? onAt; // score time the matching key went down
  double? offAt;

  /// A wrong/octave attempt seen inside the window; becomes the outcome if no correct hit follows.
  NoteOutcome? attempt;
  double attemptConfidence = 0;
  bool sawUncertainSignal = false;
  NoteResult(this.note);

  bool get isHit => outcome == NoteOutcome.correct || outcome == NoteOutcome.early || outcome == NoteOutcome.late;
}

/// Matches detected notes against expected notes. Times are score seconds; tolerances are given in real
/// seconds and scaled by [tempoFactor] so slow practice is not judged more harshly.
class NoteMatcher {
  final PracticeTimeline timeline;
  final InputKind input;
  double tempoFactor;

  /// |offset| within this (real seconds) counts as on time.
  final double onTimeTolerance;

  /// Detections within this window (real seconds) can match a note at all.
  final double window;

  /// Mic detections below this confidence are never treated as mistakes.
  final double minConfidence;

  /// Mic detections must reach this to be called a definite wrong pitch or octave.
  final double definiteConfidence;

  final Map<String, NoteResult> results = {};
  final List<PracticeFeedback> feedback = [];
  final List<double> _offsets = [];
  int extraNotes = 0;
  int earlyReleases = 0;
  int pedalChecks = 0;
  int pedalOnTime = 0;
  int uncertainSignals = 0;
  int _finalizedUpTo = 0; // index into timeline.notes
  final Map<int, NoteResult> _downKeys = {};
  final Set<int> _checkedPedals = {};
  final List<InputPedalEvent> _pedalInputs = [];

  NoteMatcher(
    this.timeline, {
    required this.input,
    this.tempoFactor = 1,
    this.onTimeTolerance = 0.12,
    this.window = 0.4,
    this.minConfidence = 0.6,
    this.definiteConfidence = 0.82,
  }) {
    for (final n in timeline.notes) {
      if (n.active) results[n.noteId] = NoteResult(n);
    }
  }

  double get _windowScore => window * tempoFactor;
  double get _onTimeScore => onTimeTolerance * tempoFactor;
  bool get _mic => input == InputKind.mic;

  List<double> get offsetsMs => _offsets.map((o) => o * 1000).toList();

  /// Reset results for notes in [from, to) seconds (new loop pass) while keeping cumulative counters elsewhere.
  void resetRange(double from, double to) {
    for (final n in timeline.notes) {
      if (n.active && n.start >= from - 1e-9 && n.start < to) results[n.noteId] = NoteResult(n);
    }
    _finalizedUpTo = 0;
    while (_finalizedUpTo < timeline.notes.length && timeline.notes[_finalizedUpTo].start < from - 1e-9) {
      _finalizedUpTo++;
    }
    _downKeys.clear();
  }

  PracticeFeedback _emit(FeedbackKind kind, double t, {int? midi, String? noteId}) {
    final f = PracticeFeedback(kind, t, midi: midi, noteId: noteId);
    feedback.add(f);
    if (feedback.length > 200) feedback.removeAt(0);
    return f;
  }

  Iterable<NoteResult> _candidates(double t) sync* {
    for (final r in results.values) {
      if (r.outcome != NoteOutcome.pending) continue;
      if ((r.note.start - t).abs() <= _windowScore) yield r;
    }
  }

  NoteResult? _nearest(Iterable<NoteResult> rs, double t) {
    NoteResult? best;
    for (final r in rs) {
      if (best == null || (r.note.start - t).abs() < (best.note.start - t).abs()) best = r;
    }
    return best;
  }

  /// Follow-along matching for a key press or detected pitch onset.
  PracticeFeedback? onNote(InputNoteEvent e) {
    if (!e.on) return _onRelease(e);
    final cands = _candidates(e.time).toList();
    final lowConf = e.confidence < minConfidence;
    if (lowConf) {
      uncertainSignals++;
      for (final r in cands) {
        r.sawUncertainSignal = true;
      }
      return _emit(FeedbackKind.uncertain, e.time, midi: e.midi);
    }
    final exact = _nearest(cands.where((r) => r.note.midi == e.midi), e.time);
    if (exact != null) {
      final off = e.time - exact.note.start;
      exact.offset = off / tempoFactor;
      exact.playedMidi = e.midi;
      exact.onAt = e.time;
      _downKeys[e.midi] = exact;
      _offsets.add(exact.offset!);
      if (off.abs() <= _onTimeScore) {
        exact.outcome = NoteOutcome.correct;
        return _emit(FeedbackKind.correct, e.time, midi: e.midi, noteId: exact.note.noteId);
      }
      exact.outcome = off < 0 ? NoteOutcome.early : NoteOutcome.late;
      return _emit(off < 0 ? FeedbackKind.early : FeedbackKind.late, e.time, midi: e.midi, noteId: exact.note.noteId);
    }
    final definite = !_mic || e.confidence >= definiteConfidence;
    final octave = _nearest(cands.where((r) => Pitch.pitchClass(r.note.midi) == Pitch.pitchClass(e.midi)), e.time);
    if (octave != null) {
      if (!definite) {
        octave.sawUncertainSignal = true;
        return _emit(FeedbackKind.uncertain, e.time, midi: e.midi);
      }
      octave.attempt = NoteOutcome.octaveMismatch;
      octave.attemptConfidence = math.max(octave.attemptConfidence, e.confidence);
      octave.playedMidi = e.midi;
      return _emit(e.midi > octave.note.midi ? FeedbackKind.octaveHigh : FeedbackKind.octaveLow, e.time,
          midi: e.midi, noteId: octave.note.noteId);
    }
    final near = _nearest(cands, e.time);
    if (near != null) {
      if (!definite) {
        near.sawUncertainSignal = true;
        return _emit(FeedbackKind.uncertain, e.time, midi: e.midi);
      }
      near.attempt ??= NoteOutcome.wrongPitch;
      near.attemptConfidence = math.max(near.attemptConfidence, e.confidence);
      near.playedMidi ??= e.midi;
      return _emit(FeedbackKind.wrong, e.time, midi: e.midi, noteId: near.note.noteId);
    }
    if (!definite) return null;
    extraNotes++;
    return _emit(FeedbackKind.extra, e.time, midi: e.midi);
  }

  PracticeFeedback? _onRelease(InputNoteEvent e) {
    final r = _downKeys.remove(e.midi);
    if (r == null || r.onAt == null) return null;
    r.offAt = e.time;
    // Key-hold is only assessed with MIDI, which reports real key release.
    if (_mic) return null;
    final held = e.time - r.onAt!;
    if (r.note.holdSec > 0.35 && held < r.note.holdSec * 0.5) {
      earlyReleases++;
      return _emit(FeedbackKind.releasedEarly, e.time, midi: e.midi, noteId: r.note.noteId);
    }
    return null;
  }

  void onUncertain(InputUncertainEvent e) {
    uncertainSignals++;
    for (final r in _candidates(e.time)) {
      r.sawUncertainSignal = true;
    }
    _emit(FeedbackKind.noisy, e.time);
  }

  void onPedal(InputPedalEvent e) {
    if (input != InputKind.midi) return;
    _pedalInputs.add(e);
  }

  /// Finalize notes whose matching window ended before [t]. Returns feedback for misses.
  List<PracticeFeedback> advance(double t) {
    final out = <PracticeFeedback>[];
    final notes = timeline.notes;
    while (_finalizedUpTo < notes.length && notes[_finalizedUpTo].start + _windowScore < t) {
      final n = notes[_finalizedUpTo++];
      final r = results[n.noteId];
      if (r == null || r.outcome != NoteOutcome.pending) continue;
      r.outcome = _finalOutcome(r);
      if (r.outcome == NoteOutcome.missed) {
        out.add(_emit(_mic ? FeedbackKind.notHeard : FeedbackKind.wrong, t, midi: n.midi, noteId: n.noteId));
      }
    }
    _assessPedals(t);
    return out;
  }

  NoteOutcome _finalOutcome(NoteResult r) {
    if (_mic) {
      // Monophonic detection: if another note of the same chord was heard, this one cannot be assessed.
      final chordHeard = results.values.any((o) => o != r && o.isHit && (o.note.startTick - r.note.startTick).abs() <= PracticeTimeline.chordTolerance);
      if (chordHeard) return NoteOutcome.notAssessed;
      if (r.attempt != null && r.attemptConfidence >= definiteConfidence) return r.attempt!;
      if (r.attempt != null || r.sawUncertainSignal) return NoteOutcome.uncertain;
      return NoteOutcome.missed;
    }
    return r.attempt ?? NoteOutcome.missed;
  }

  void _assessPedals(double t) {
    if (input != InputKind.midi) return;
    final tol = 0.5 * tempoFactor;
    for (var i = 0; i < timeline.pedals.length; i++) {
      final p = timeline.pedals[i];
      if (!p.certain || _checkedPedals.contains(i) || p.time + tol >= t) continue;
      _checkedPedals.add(i);
      pedalChecks++;
      if (_pedalInputs.any((e) => e.down == p.down && (e.time - p.time).abs() <= tol)) pedalOnTime++;
    }
  }

  // ---- Wait mode -------------------------------------------------------------------------------

  /// Wait-mode matching: only the chord being waited on is considered, timing is not judged.
  /// Returns feedback; the chord is complete when [chordSatisfied] is true.
  PracticeFeedback? onNoteWaiting(InputNoteEvent e, ExpectedChord chord) {
    if (!e.on) return _onRelease(e);
    final pending = [
      for (final n in chord.notes)
        if (results[n.noteId]?.outcome == NoteOutcome.pending) results[n.noteId]!,
    ];
    if (e.confidence < minConfidence) {
      uncertainSignals++;
      for (final r in pending) {
        r.sawUncertainSignal = true;
      }
      return _emit(FeedbackKind.uncertain, e.time, midi: e.midi);
    }
    for (final r in pending) {
      if (r.note.midi == e.midi) {
        r.outcome = NoteOutcome.correct;
        r.playedMidi = e.midi;
        r.onAt = e.time;
        _downKeys[e.midi] = r;
        if (_mic) {
          // Mic hears one pitch: the rest of the chord is not assessed.
          for (final o in pending) {
            if (o != r) o.outcome = NoteOutcome.notAssessed;
          }
        }
        return _emit(FeedbackKind.correct, e.time, midi: e.midi, noteId: r.note.noteId);
      }
    }
    final definite = !_mic || e.confidence >= definiteConfidence;
    if (!definite) return _emit(FeedbackKind.uncertain, e.time, midi: e.midi);
    for (final r in pending) {
      if (Pitch.pitchClass(r.note.midi) == Pitch.pitchClass(e.midi)) {
        r.attempt = NoteOutcome.octaveMismatch;
        r.attemptConfidence = e.confidence;
        return _emit(e.midi > r.note.midi ? FeedbackKind.octaveHigh : FeedbackKind.octaveLow, e.time,
            midi: e.midi, noteId: r.note.noteId);
      }
    }
    if (pending.isNotEmpty) {
      pending.first.attempt ??= NoteOutcome.wrongPitch;
      pending.first.attemptConfidence = math.max(pending.first.attemptConfidence, e.confidence);
    }
    return _emit(FeedbackKind.wrong, e.time, midi: e.midi);
  }

  bool chordSatisfied(ExpectedChord chord) =>
      chord.notes.every((n) => (results[n.noteId]?.outcome ?? NoteOutcome.skipped) != NoteOutcome.pending);

  /// User skipped (or wait timeout). Notes with a confident wrong attempt keep it; others become skipped.
  void skipChord(ExpectedChord chord) {
    for (final n in chord.notes) {
      final r = results[n.noteId];
      if (r == null || r.outcome != NoteOutcome.pending) continue;
      r.outcome = NoteOutcome.skipped;
    }
  }

  /// Drop unplayed notes before [t] (seek, loop start) so they are neither scored nor counted.
  void skipBefore(double t) {
    results.removeWhere((_, r) => r.outcome == NoteOutcome.pending && r.note.start < t - 1e-9);
    while (_finalizedUpTo < timeline.notes.length && timeline.notes[_finalizedUpTo].start < t) {
      _finalizedUpTo++;
    }
  }

  /// Fill a [PracticeSession] with counts from the current results.
  void writeTo(PracticeSession s) {
    s
      ..correct = 0
      ..early = 0
      ..late = 0
      ..wrongPitch = 0
      ..octaveMismatch = 0
      ..missed = 0
      ..uncertain = 0
      ..skipped = 0
      ..notAssessed = 0;
    for (final r in results.values) {
      if (r.outcome == NoteOutcome.pending) continue;
      final ms = s.perMeasure.putIfAbsent(r.note.measure, MeasureStat.new);
      ms.expected++;
      switch (r.outcome) {
        case NoteOutcome.correct:
          s.correct++;
          ms.correct++;
        case NoteOutcome.early:
          s.early++;
          ms.correct++;
        case NoteOutcome.late:
          s.late++;
          ms.correct++;
        case NoteOutcome.wrongPitch:
          s.wrongPitch++;
          ms.errors++;
          s.missedPitches[r.note.midi] = (s.missedPitches[r.note.midi] ?? 0) + 1;
        case NoteOutcome.octaveMismatch:
          s.octaveMismatch++;
          ms.errors++;
          s.missedPitches[r.note.midi] = (s.missedPitches[r.note.midi] ?? 0) + 1;
        case NoteOutcome.missed:
          s.missed++;
          ms.errors++;
          s.missedPitches[r.note.midi] = (s.missedPitches[r.note.midi] ?? 0) + 1;
        case NoteOutcome.uncertain:
          s.uncertain++;
          ms.uncertain++;
        case NoteOutcome.skipped:
          s.skipped++;
          ms.uncertain++;
        case NoteOutcome.notAssessed:
          s.notAssessed++;
          ms.uncertain++;
        case NoteOutcome.pending:
          break;
      }
    }
    s.extraNotes = extraNotes;
    s.earlyReleases = earlyReleases;
    s.pedalChecks = pedalChecks;
    s.pedalOnTime = pedalOnTime;
    if (_offsets.length >= 4) {
      final ms = offsetsMs;
      final mean = ms.reduce((a, b) => a + b) / ms.length;
      final variance = ms.map((x) => (x - mean) * (x - mean)).reduce((a, b) => a + b) / ms.length;
      s.meanOffsetMs = mean;
      s.timingSpreadMs = math.sqrt(variance);
    }
    final judged = s.assessed + s.uncertain;
    s.lowQuality = judged >= 4 && s.uncertain / judged > 0.5;
  }
}
