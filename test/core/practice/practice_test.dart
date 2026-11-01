import 'package:flutter_test/flutter_test.dart';
import 'package:stavelight/core/model/pitch.dart';
import 'package:stavelight/core/model/score.dart';
import 'package:stavelight/core/model/session.dart';
import 'package:stavelight/core/practice/input_event.dart';
import 'package:stavelight/core/practice/matcher.dart';
import 'package:stavelight/core/practice/practice_engine.dart';
import 'package:stavelight/core/practice/timeline.dart';

/// 2 measures of 4/4 at 120 bpm (0.5 s per quarter). RH quarters C4 D4 E4 F4 | G4 half, LH C3 whole | C3 whole.
Score buildScore() {
  final notes = <ScoreNote>[];
  var i = 0;
  for (final (m, t) in [(60, 0), (62, 480), (64, 960), (65, 1440)]) {
    notes.add(ScoreNote(id: 'r${i++}', midi: m, startTick: t, durationTicks: 480, hand: Hand.right));
  }
  notes.add(ScoreNote(id: 'r${i++}', midi: 67, startTick: 1920, durationTicks: 960, hand: Hand.right));
  notes.add(ScoreNote(id: 'l0', midi: 48, startTick: 0, durationTicks: 1920, hand: Hand.left, staff: 2));
  notes.add(ScoreNote(id: 'l1', midi: 48, startTick: 1920, durationTicks: 1920, hand: Hand.left, staff: 2));
  return Score(
    title: 't',
    origin: ScoreOrigin.manual,
    notes: notes,
    tempos: [TempoEvent(0, 120)],
    measures: [
      Measure(index: 0, startTick: 0, lengthTicks: 1920, number: '1', time: const TimeSignature(4, 4), key: const KeySignature(0)),
      Measure(index: 1, startTick: 1920, lengthTicks: 1920, number: '2', time: const TimeSignature(4, 4), key: const KeySignature(0)),
    ],
  )..normalize();
}

class FakeSound implements EngineSound {
  int clicks = 0, accents = 0;
  final played = <int>[];
  @override
  void click({required bool accent}) {
    clicks++;
    if (accent) accents++;
  }

  @override
  void noteOn(int midi, int velocity) => played.add(midi);
  @override
  void noteOff(int midi) {}
  @override
  void allOff() {}
}

InputNoteEvent on(int midi, {double conf = 1, InputKind src = InputKind.midi}) =>
    InputNoteEvent(midi: midi, time: 0, on: true, confidence: conf, source: src);

void run(PracticeEngine e, double seconds) {
  const dt = 1 / 120;
  for (var t = 0.0; t < seconds; t += dt) {
    e.tick(dt);
  }
}

void main() {
  test('timeline groups chords, filters hands, transposes', () {
    final tl = PracticeTimeline.build(buildScore(), hands: HandsSelection.right, transpose: 2);
    expect(tl.chords.length, 5);
    expect(tl.chords.first.notes.single.midi, 62);
    expect(tl.notes.where((n) => !n.active).length, 2);
    expect(tl.chords[1].start, closeTo(0.5, 1e-9));
    expect(tl.beats.length, 8);
    final both = PracticeTimeline.build(buildScore());
    expect(both.chords.first.notes.length, 2); // C4 + C3
  });

  test('tied continuation is not a new key press and hold spans the chain', () {
    final s = buildScore();
    s.notes.removeWhere((n) => n.id == 'r4');
    s.notes.add(ScoreNote(id: 'a', midi: 67, startTick: 1920, durationTicks: 960, holdTicks: 1920, tieStart: true, hand: Hand.right));
    s.notes.add(ScoreNote(id: 'b', midi: 67, startTick: 2880, durationTicks: 960, tieStop: true, hand: Hand.right));
    s.normalize();
    final tl = PracticeTimeline.build(s, hands: HandsSelection.right);
    expect(tl.notes.where((n) => n.midi == 67).length, 1);
    expect(tl.notes.firstWhere((n) => n.midi == 67).holdSec, closeTo(2.0, 1e-9));
  });

  test('matcher classifies correct, early, late, octave, wrong and missed (MIDI)', () {
    final tl = PracticeTimeline.build(buildScore(), hands: HandsSelection.right);
    final m = NoteMatcher(tl, input: InputKind.midi);
    expect(m.onNote(InputNoteEvent(midi: 60, time: 0.02, on: true))!.kind, FeedbackKind.correct);
    expect(m.onNote(InputNoteEvent(midi: 62, time: 0.30, on: true))!.kind, FeedbackKind.early);
    expect(m.onNote(InputNoteEvent(midi: 76, time: 1.0, on: true))!.kind, FeedbackKind.octaveHigh);
    expect(m.onNote(InputNoteEvent(midi: 66, time: 1.5, on: true))!.kind, FeedbackKind.wrong);
    m.onNote(InputNoteEvent(midi: 67, time: 2.25, on: true)); // late
    m.advance(10);
    final s = PracticeSession(id: 'x', pieceId: null, startedAt: DateTime.now());
    m.writeTo(s);
    expect(s.correct, 1);
    expect(s.early, 1);
    expect(s.late, 1);
    expect(s.octaveMismatch, 1);
    expect(s.wrongPitch, 1);
    expect(s.missed, 0);
  });

  test('correct note after a wrong attempt in the window still counts as correct', () {
    final tl = PracticeTimeline.build(buildScore(), hands: HandsSelection.right);
    final m = NoteMatcher(tl, input: InputKind.midi);
    m.onNote(InputNoteEvent(midi: 61, time: 0.0, on: true));
    m.onNote(InputNoteEvent(midi: 60, time: 0.05, on: true));
    m.advance(1);
    expect(m.results['r0']!.outcome, NoteOutcome.correct);
  });

  test('low-confidence mic detections are never scored as mistakes', () {
    final tl = PracticeTimeline.build(buildScore(), hands: HandsSelection.right);
    final m = NoteMatcher(tl, input: InputKind.mic);
    expect(m.onNote(InputNoteEvent(midi: 70, time: 0.0, on: true, confidence: 0.4, source: InputKind.mic))!.kind,
        FeedbackKind.uncertain);
    // Moderately confident octave error from mic: reported as uncertain, not octave mismatch.
    expect(m.onNote(InputNoteEvent(midi: 74, time: 0.5, on: true, confidence: 0.7, source: InputKind.mic))!.kind,
        FeedbackKind.uncertain);
    m.advance(10);
    expect(m.results['r0']!.outcome, NoteOutcome.uncertain);
    expect(m.results['r1']!.outcome, NoteOutcome.uncertain);
    expect(m.results['r2']!.outcome, NoteOutcome.missed); // silence: not heard
  });

  test('mic chord: one heard note → others not assessed', () {
    final tl = PracticeTimeline.build(buildScore());
    final m = NoteMatcher(tl, input: InputKind.mic);
    m.onNote(InputNoteEvent(midi: 60, time: 0.0, on: true, confidence: 0.95, source: InputKind.mic));
    m.advance(1);
    expect(m.results['r0']!.outcome, NoteOutcome.correct);
    expect(m.results['l0']!.outcome, NoteOutcome.notAssessed);
  });

  test('MIDI early key release is reported, pedal timing assessed separately', () {
    final s = buildScore()
      ..pedals.add(PedalEvent(id: 'p1', tick: 0, type: PedalType.down, verified: true))
      ..pedals.add(PedalEvent(id: 'p2', tick: 1900, type: PedalType.up, verified: true));
    final tl = PracticeTimeline.build(s, hands: HandsSelection.left);
    final m = NoteMatcher(tl, input: InputKind.midi);
    m.onPedal(const InputPedalEvent(0.05, true));
    m.onNote(InputNoteEvent(midi: 48, time: 0.0, on: true));
    final f = m.onNote(InputNoteEvent(midi: 48, time: 0.5, on: false)); // whole note held 0.5 of 2 s
    expect(f!.kind, FeedbackKind.releasedEarly);
    m.advance(10);
    expect(m.pedalChecks, 2);
    expect(m.pedalOnTime, 1);
  });

  test('wait mode stops at each chord until played, and skip releases it', () {
    final snd = FakeSound();
    final e = PracticeEngine(
      PracticeTimeline.build(buildScore(), hands: HandsSelection.right),
      PracticeConfig(mode: PracticeMode.wait, countInBeats: 0, hands: HandsSelection.right, waitTimeout: 3),
      input: InputKind.midi,
      sound: snd,
    );
    e.start();
    run(e, 0.1);
    expect(e.state, EngineState.waiting);
    expect(e.position, 0);
    run(e, 5); // nobody plays: clock must not advance
    expect(e.position, 0);
    expect(e.canSkip, isTrue);
    e.handleNote(on(60));
    expect(e.state, EngineState.playing);
    run(e, 0.6);
    expect(e.state, EngineState.waiting);
    expect(e.position, closeTo(0.5, 1e-9));
    e.skip();
    expect(e.matcher.results['r1']!.outcome, NoteOutcome.skipped);
    expect(e.state, EngineState.playing);
  });

  test('follow mode advances with tempo factor and plays the other hand', () {
    final snd = FakeSound();
    final e = PracticeEngine(
      PracticeTimeline.build(buildScore(), hands: HandsSelection.right),
      PracticeConfig(countInBeats: 4, tempoFactor: 0.5, hands: HandsSelection.right),
      input: InputKind.midi,
      sound: snd,
    );
    e.start();
    expect(e.state, EngineState.countIn);
    run(e, 4.0); // 4 beats at half speed = 4 s
    expect(e.state, EngineState.playing);
    run(e, 1.0);
    expect(e.position, closeTo(0.5, 0.03));
    expect(snd.played, contains(48)); // left hand accompaniment
    expect(snd.played, isNot(contains(60))); // practiced hand is not auto-played
    run(e, 10);
    expect(e.state, EngineState.finished);
    final s = e.summarize(id: 's', pieceId: 'p', startedAt: DateTime.now());
    expect(s.missed, 5);
    expect(s.tempoPct, 50);
  });

  test('section loop wraps to loop start and accumulates passes', () {
    final e = PracticeEngine(
      PracticeTimeline.build(buildScore(), hands: HandsSelection.right),
      PracticeConfig(countInBeats: 0, hands: HandsSelection.right, loop: true, loopStart: 1, loopEnd: 1, countInEachLoop: false),
      input: InputKind.midi,
    );
    expect(e.position, closeTo(2.0, 1e-9));
    e.start();
    run(e, 0.05);
    e.handleNote(on(67));
    run(e, 2.1);
    expect(e.loopPasses, 1);
    expect(e.position, lessThan(2.2));
    run(e, 0.05);
    e.handleNote(on(67));
    run(e, 2.0);
    final s = e.summarize(id: 's', pieceId: 'p', startedAt: DateTime.now());
    expect(s.correct + s.early + s.late, 2);
    expect(s.perMeasure.keys, [1]);
  });

  test('not listening: nothing is scored, measures visited are still counted', () {
    final e = PracticeEngine(
      PracticeTimeline.build(buildScore()),
      PracticeConfig(countInBeats: 0),
      input: InputKind.none,
    );
    e.start();
    run(e, 6);
    expect(e.state, EngineState.finished);
    final s = e.summarize(id: 's', pieceId: 'p', startedAt: DateTime.now());
    expect(s.assessed, 0);
    expect(s.perMeasure, isEmpty);
    expect(s.measuresCompleted, 2);
  });
}
