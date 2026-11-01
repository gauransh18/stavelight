import '../model/session.dart';
import 'input_event.dart';
import 'matcher.dart';
import 'timeline.dart';

enum EngineState { idle, countIn, playing, waiting, paused, finished }

/// Callbacks the engine uses to make sound. Implemented by the audio adapter (or a fake in tests).
abstract class EngineSound {
  void click({required bool accent});
  void noteOn(int midi, int velocity);
  void noteOff(int midi);
  void allOff();
}

class PracticeConfig {
  PracticeMode mode;
  HandsSelection hands;
  double tempoFactor; // 0.25..1.5
  int transpose;
  bool metronome;
  bool accentDownbeat;
  int countInBeats; // 0 = none
  bool loop;
  int? loopStart; // measure index inclusive
  int? loopEnd; // measure index inclusive
  bool countInEachLoop;

  /// Play notes of the hand not being practiced (and all notes in demo mode).
  bool playOtherHand;

  /// Play the practiced notes too (listen / preview mode). No scoring.
  bool demo;

  /// Wait mode: seconds before the skip action is offered; [autoSkip] advances by itself.
  double waitTimeout;
  bool autoSkip;

  PracticeConfig({
    this.mode = PracticeMode.follow,
    this.hands = HandsSelection.both,
    this.tempoFactor = 1,
    this.transpose = 0,
    this.metronome = true,
    this.accentDownbeat = true,
    this.countInBeats = 4,
    this.loop = false,
    this.loopStart,
    this.loopEnd,
    this.countInEachLoop = true,
    this.playOtherHand = true,
    this.demo = false,
    this.waitTimeout = 8,
    this.autoSkip = false,
  });
}

/// Drives practice: clock, count-in, metronome, follow/wait progression, looping and accompaniment.
/// Pure Dart; the UI calls [tick] every frame with the real elapsed time.
class PracticeEngine {
  PracticeTimeline timeline;
  final PracticeConfig config;
  final InputKind input;
  final EngineSound? sound;
  late NoteMatcher matcher;

  EngineState state = EngineState.idle;
  EngineState _stateBeforePause = EngineState.playing;

  /// Current position in score seconds (100% tempo time base).
  double position = 0;
  double realElapsed = 0; // active practice time (excludes pauses)
  double countInRemaining = 0;
  int countInBeatsLeft = 0;
  double _countInBeatLen = 0;
  double waitElapsed = 0;
  int loopPasses = 0;
  ExpectedChord? waitingFor;
  int _nextChord = 0;
  int _nextBeat = 0;
  int _nextAccomp = 0;
  final Set<int> _sounding = {};
  final List<(double, int)> _pendingOffs = []; // (score time, midi)
  void Function(PracticeFeedback)? onFeedback;

  /// Measures the cursor has been in, for the summary (independent of scoring).
  final Set<int> visitedMeasures = {};

  /// Seconds of analysis delay to subtract from microphone onsets.
  double micLatency = 0.07;
  void Function()? onLoopWrap;

  PracticeEngine(this.timeline, this.config, {required this.input, this.sound}) {
    matcher = NoteMatcher(timeline, input: input, tempoFactor: config.tempoFactor);
    position = rangeStart;
    matcher.skipBefore(position);
    _syncCursors();
  }

  double get rangeStart => config.loopStart != null ? timeline.measureStart(config.loopStart!) : 0;
  double get rangeEnd => config.loopEnd != null ? timeline.measureEnd(config.loopEnd!) : timeline.duration;

  int get currentMeasure => timeline.measureAt(position);
  bool get canSkip => state == EngineState.waiting && waitElapsed >= config.waitTimeout;
  bool get isRunning => state == EngineState.playing || state == EngineState.waiting || state == EngineState.countIn;

  bool get _scoring => !config.demo && input != InputKind.none && config.mode != PracticeMode.freePlay;

  void setTempo(double factor) {
    config.tempoFactor = factor.clamp(0.25, 1.5);
    matcher.tempoFactor = config.tempoFactor;
  }

  void setTranspose(int semitones) {
    config.transpose = semitones.clamp(-12, 12);
    _rebuild();
  }

  void setHands(HandsSelection hands) {
    config.hands = hands;
    _rebuild();
  }

  void _rebuild() {
    final old = matcher;
    timeline = PracticeTimeline.build(timeline.score, transpose: config.transpose, hands: config.hands);
    matcher = NoteMatcher(timeline, input: input, tempoFactor: config.tempoFactor)
      ..extraNotes = old.extraNotes
      ..earlyReleases = old.earlyReleases;
    matcher.skipBefore(position);
    _syncCursors();
  }

  void setLoop(int? start, int? end, {bool enabled = true}) {
    config.loopStart = start;
    config.loopEnd = end;
    config.loop = enabled && start != null;
    if (position < rangeStart || position >= rangeEnd) seek(rangeStart);
  }

  void start() {
    if (state == EngineState.paused) {
      resume();
      return;
    }
    if (state == EngineState.finished) {
      restart();
      return;
    }
    _beginCountIn();
  }

  void _beginCountIn() {
    final beats = config.countInBeats;
    if (beats <= 0) {
      state = EngineState.playing;
      return;
    }
    _countInBeatLen = timeline.beatLengthAt(position) / config.tempoFactor;
    countInBeatsLeft = beats;
    countInRemaining = 0;
    state = EngineState.countIn;
  }

  void pause() {
    if (!isRunning) return;
    _stateBeforePause = state == EngineState.countIn ? EngineState.playing : state;
    state = EngineState.paused;
    _silence();
  }

  void resume() {
    if (state != EngineState.paused) return;
    if (_stateBeforePause == EngineState.waiting) {
      state = EngineState.waiting;
    } else {
      _beginCountIn();
    }
  }

  void stop() {
    state = EngineState.idle;
    _silence();
  }

  void restart() {
    _silence();
    matcher.resetRange(rangeStart, rangeEnd);
    position = rangeStart;
    waitingFor = null;
    _syncCursors();
    _beginCountIn();
  }

  /// Jump to a position. Notes before it are not scored.
  void seek(double t) {
    _silence();
    position = t.clamp(0, timeline.duration);
    waitingFor = null;
    if (state == EngineState.waiting) state = EngineState.playing;
    matcher.resetRange(position, timeline.duration);
    matcher.skipBefore(position);
    _syncCursors();
  }

  void seekMeasure(int index) => seek(timeline.measureStart(index.clamp(0, timeline.measureCount - 1)));
  void nextMeasure() => seekMeasure(currentMeasure + 1);
  void previousMeasure() {
    final m = currentMeasure;
    final intoMeasure = position - timeline.measureStart(m);
    seekMeasure(intoMeasure > 0.5 ? m : m - 1);
  }

  void _syncCursors() {
    _nextChord = timeline.chords.indexWhere((c) => c.start >= position - 1e-9);
    if (_nextChord < 0) _nextChord = timeline.chords.length;
    _nextBeat = timeline.beats.indexWhere((b) => b.time >= position - 1e-9);
    if (_nextBeat < 0) _nextBeat = timeline.beats.length;
    _nextAccomp = timeline.notes.indexWhere((n) => n.start >= position - 1e-9);
    if (_nextAccomp < 0) _nextAccomp = timeline.notes.length;
  }

  void _silence() {
    for (final m in _sounding) {
      sound?.noteOff(m);
    }
    _sounding.clear();
    _pendingOffs.clear();
    sound?.allOff();
  }

  /// Skip the chord being waited on (Wait Mode), so a missed note cannot trap the player.
  void skip() {
    final c = waitingFor;
    if (c == null) return;
    matcher.skipChord(c);
    _releaseWait();
  }

  void _releaseWait() {
    waitingFor = null;
    waitElapsed = 0;
    _nextChord++;
    state = EngineState.playing;
  }

  // ---- Input -----------------------------------------------------------------------------------

  /// Feed a note event. [InputNoteEvent.time] is ignored; the engine stamps it with the current position.
  PracticeFeedback? handleNote(InputNoteEvent raw) {
    if (!_scoring || state == EngineState.paused || state == EngineState.idle || state == EngineState.finished) {
      return null;
    }
    // Mic detection needs ~2 analysis frames before reporting a pitch; compensate so timing isn't biased late.
    final latency = raw.source == InputKind.mic && raw.on ? micLatency * config.tempoFactor : 0.0;
    final e = InputNoteEvent(
      midi: raw.midi,
      time: position - latency,
      on: raw.on,
      confidence: raw.confidence,
      source: raw.source,
      velocity: raw.velocity,
    );
    PracticeFeedback? f;
    if (config.mode == PracticeMode.wait && waitingFor != null) {
      f = matcher.onNoteWaiting(e, waitingFor!);
      if (matcher.chordSatisfied(waitingFor!)) _releaseWait();
    } else if (config.mode == PracticeMode.wait) {
      // Pressed slightly before the cursor reached the chord: accept for the upcoming chord.
      final upcoming = _nextChord < timeline.chords.length ? timeline.chords[_nextChord] : null;
      if (upcoming != null && e.on && upcoming.start - position <= 0.25 * config.tempoFactor) {
        f = matcher.onNoteWaiting(e, upcoming);
        if (matcher.chordSatisfied(upcoming)) _nextChord++;
      } else {
        f = matcher.onNote(e);
      }
    } else {
      f = matcher.onNote(e);
    }
    if (f != null) onFeedback?.call(f);
    return f;
  }

  void handleUncertain(InputUncertainEvent raw) {
    if (!_scoring || !isRunning) return;
    matcher.onUncertain(InputUncertainEvent(position, raw.reason));
  }

  void handlePedal(InputPedalEvent raw) {
    if (!_scoring) return;
    matcher.onPedal(InputPedalEvent(position, raw.down));
  }

  // ---- Clock -----------------------------------------------------------------------------------

  void tick(double dtReal) {
    if (dtReal <= 0) return;
    switch (state) {
      case EngineState.countIn:
        realElapsed += dtReal;
        _tickCountIn(dtReal);
      case EngineState.playing:
        realElapsed += dtReal;
        _advance(dtReal * config.tempoFactor);
      case EngineState.waiting:
        realElapsed += dtReal;
        waitElapsed += dtReal;
        if (config.autoSkip && waitElapsed >= config.waitTimeout) skip();
      case EngineState.idle:
      case EngineState.paused:
      case EngineState.finished:
        break;
    }
  }

  void _tickCountIn(double dt) {
    countInRemaining -= dt;
    while (countInRemaining <= 0 && countInBeatsLeft > 0) {
      sound?.click(accent: countInBeatsLeft == config.countInBeats);
      countInBeatsLeft--;
      countInRemaining += _countInBeatLen;
    }
    if (countInBeatsLeft == 0 && countInRemaining <= 0) {
      state = EngineState.playing;
      _advance(-countInRemaining * config.tempoFactor);
    }
  }

  void _advance(double dScore) {
    var target = position + dScore;

    // Wait mode: stop at the next chord that hasn't been played yet.
    if (config.mode == PracticeMode.wait && _scoring) {
      while (_nextChord < timeline.chords.length && matcher.chordSatisfied(timeline.chords[_nextChord])) {
        _nextChord++;
      }
      if (_nextChord < timeline.chords.length) {
        final c = timeline.chords[_nextChord];
        if (c.start <= target && c.start < rangeEnd) {
          target = c.start;
          _emitUpTo(target);
          position = target;
          waitingFor = c;
          waitElapsed = 0;
          state = EngineState.waiting;
          return;
        }
      }
    }

    if (target >= rangeEnd) {
      _emitUpTo(rangeEnd);
      position = rangeEnd;
      if (_scoring) {
        for (final f in matcher.advance(rangeEnd + matcher.window * config.tempoFactor + 0.01)) {
          onFeedback?.call(f);
        }
      }
      if (config.loop) {
        loopPasses++;
        onLoopWrap?.call();
        _accumulatePass();
        _silence();
        matcher.resetRange(rangeStart, rangeEnd);
        position = rangeStart;
        _syncCursors();
        if (config.countInEachLoop && config.countInBeats > 0) {
          _beginCountIn();
        }
      } else {
        _silence();
        state = EngineState.finished;
      }
      return;
    }
    _emitUpTo(target);
    position = target;
    visitedMeasures.add(currentMeasure);
    if (_scoring) {
      for (final f in matcher.advance(position)) {
        onFeedback?.call(f);
      }
    }
  }

  /// Fire metronome clicks, accompaniment note-ons and scheduled note-offs between position and [t].
  void _emitUpTo(double t) {
    while (_nextBeat < timeline.beats.length && timeline.beats[_nextBeat].time <= t) {
      final b = timeline.beats[_nextBeat++];
      if (config.metronome && b.time >= position - 1e-9) sound?.click(accent: config.accentDownbeat && b.downbeat);
    }
    _pendingOffs.sort((a, b) => a.$1.compareTo(b.$1));
    while (_pendingOffs.isNotEmpty && _pendingOffs.first.$1 <= t) {
      final m = _pendingOffs.removeAt(0).$2;
      if (_sounding.remove(m)) sound?.noteOff(m);
    }
    while (_nextAccomp < timeline.notes.length && timeline.notes[_nextAccomp].start <= t) {
      final n = timeline.notes[_nextAccomp++];
      final play = config.demo || (!n.active && config.playOtherHand) || (n.active && !_scoring);
      if (!play || n.start < position - 1e-9) continue;
      if (_sounding.contains(n.midi)) sound?.noteOff(n.midi);
      sound?.noteOn(n.midi, 80);
      _sounding.add(n.midi);
      _pendingOffs.add((n.start + n.holdSec, n.midi));
    }
  }

  final PracticeSession _passTotals = PracticeSession(id: '', pieceId: null, startedAt: DateTime(2000));

  /// Loop passes reset per-note results; keep their counts so the summary covers every pass.
  void _accumulatePass() {
    final pass = PracticeSession(id: '', pieceId: null, startedAt: DateTime(2000));
    matcher.writeTo(pass);
    _passTotals
      ..correct += pass.correct
      ..early += pass.early
      ..late += pass.late
      ..wrongPitch += pass.wrongPitch
      ..octaveMismatch += pass.octaveMismatch
      ..missed += pass.missed
      ..uncertain += pass.uncertain
      ..skipped += pass.skipped
      ..notAssessed += pass.notAssessed;
    pass.perMeasure.forEach((k, v) {
      final t = _passTotals.perMeasure.putIfAbsent(k, MeasureStat.new);
      t
        ..expected += v.expected
        ..correct += v.correct
        ..errors += v.errors
        ..uncertain += v.uncertain;
    });
    pass.missedPitches.forEach((k, v) => _passTotals.missedPitches[k] = (_passTotals.missedPitches[k] ?? 0) + v);
  }

  /// Build the session summary from what has been played so far.
  PracticeSession summarize({required String id, required String? pieceId, required DateTime startedAt}) {
    final s = PracticeSession(
      id: id,
      pieceId: pieceId,
      startedAt: startedAt,
      durationSec: realElapsed.round(),
      mode: config.mode,
      input: input,
      hands: config.hands,
      tempoPct: config.tempoFactor * 100,
      transpose: config.transpose,
      loopStart: config.loop ? config.loopStart : null,
      loopEnd: config.loop ? config.loopEnd : null,
    );
    matcher.writeTo(s);
    final t = _passTotals;
    s
      ..correct += t.correct
      ..early += t.early
      ..late += t.late
      ..wrongPitch += t.wrongPitch
      ..octaveMismatch += t.octaveMismatch
      ..missed += t.missed
      ..uncertain += t.uncertain
      ..skipped += t.skipped
      ..notAssessed += t.notAssessed;
    t.perMeasure.forEach((k, v) {
      final m = s.perMeasure.putIfAbsent(k, MeasureStat.new);
      m
        ..expected += v.expected
        ..correct += v.correct
        ..errors += v.errors
        ..uncertain += v.uncertain;
    });
    t.missedPitches.forEach((k, v) => s.missedPitches[k] = (s.missedPitches[k] ?? 0) + v);
    final judged = s.assessed + s.uncertain;
    s.lowQuality = judged >= 4 && s.uncertain / judged > 0.5;
    s.measuresCompleted = visitedMeasures.length;
    return s;
  }
}
