import '../model/pitch.dart';
import '../model/score.dart';
import '../util/ids.dart';

/// Editing operations on a [Score] with snapshot-based undo/redo.
/// Every edit marks what it touched as verified, since the user has now looked at it.
class ScoreEditor {
  Score score;
  final List<Map<String, dynamic>> _undo = [];
  final List<Map<String, dynamic>> _redo = [];
  final int maxHistory;
  void Function(Score)? onChanged;

  ScoreEditor(this.score, {this.maxHistory = 100, this.onChanged});

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  void _edit(void Function() change) {
    _undo.add(score.toJson());
    if (_undo.length > maxHistory) _undo.removeAt(0);
    _redo.clear();
    change();
    score.normalize();
    onChanged?.call(score);
  }

  void undo() {
    if (!canUndo) return;
    _redo.add(score.toJson());
    score = Score.fromJson(_undo.removeLast());
    onChanged?.call(score);
  }

  void redo() {
    if (!canRedo) return;
    _undo.add(score.toJson());
    score = Score.fromJson(_redo.removeLast());
    onChanged?.call(score);
  }

  ScoreNote? note(String id) {
    for (final n in score.notes) {
      if (n.id == id) return n;
    }
    return null;
  }

  void _touch(ScoreNote n) {
    n.verified = true;
    n.flags.clear();
  }

  void setPitch(String id, int midi) => _edit(() {
        final n = note(id);
        if (n == null) return;
        n.midi = midi.clamp(0, 127);
        _touch(n);
      });

  void shiftOctave(String id, int octaves) => _edit(() {
        final n = note(id);
        if (n == null) return;
        n.midi = (n.midi + 12 * octaves).clamp(0, 127);
        _touch(n);
      });

  void transposeSemitones(String id, int semitones) => _edit(() {
        final n = note(id);
        if (n == null) return;
        n.midi = (n.midi + semitones).clamp(0, 127);
        _touch(n);
      });

  /// Set an explicit accidental (-1 flat, 0 natural, 1 sharp) relative to the natural letter of the note.
  void setAccidental(String id, int alter, {bool preferFlatSpelling = false}) => _edit(() {
        final n = note(id);
        if (n == null) return;
        final natural = _naturalOf(n, preferFlatSpelling || (n.accidental ?? 0) < 0);
        n.midi = (natural + alter).clamp(0, 127);
        n.accidental = alter;
        _touch(n);
      });

  /// The white-key (natural) pitch a notehead sits on, from its current spelling.
  int _naturalOf(ScoreNote n, bool flatSpelled) {
    if (!Pitch.isBlack(n.midi)) {
      final acc = n.accidental ?? 0;
      return n.midi - acc;
    }
    return flatSpelled ? n.midi + 1 : n.midi - 1;
  }

  /// Change written duration. Hold follows unless the hold was independently set from MIDI.
  void setDuration(String id, int ticks, {int dots = 0}) => _edit(() {
        final n = note(id);
        if (n == null) return;
        final holdFollowed = n.holdTicks == null || n.holdTicks == n.durationTicks;
        n.durationTicks = ticks;
        n.dots = dots;
        if (holdFollowed && !n.tieStart) n.holdTicks = null;
        _touch(n);
      });

  void setHold(String id, int? ticks) => _edit(() {
        final n = note(id);
        if (n == null) return;
        n.holdTicks = ticks;
        _touch(n);
      });

  void setVoice(String id, int voice) => _edit(() {
        final n = note(id);
        if (n == null) return;
        n.voice = voice;
        _touch(n);
      });

  void setHand(String id, Hand hand) => _edit(() {
        final n = note(id);
        if (n == null) return;
        n.hand = hand;
        if (hand != Hand.unassigned) n.staff = hand == Hand.right ? 1 : 2;
        _touch(n);
      });

  void setHandForMeasure(int measureIndex, Hand hand, {int? staff}) => _edit(() {
        for (final n in score.notes) {
          if (n.measureIndex == measureIndex && (staff == null || n.staff == staff)) {
            n.hand = hand;
          }
        }
      });

  void moveNote(String id, int newStartTick) => _edit(() {
        final n = note(id);
        if (n == null) return;
        n.startTick = newStartTick < 0 ? 0 : newStartTick;
        _touch(n);
      });

  void deleteNote(String id) => _edit(() => score.notes.removeWhere((n) => n.id == id));

  String addNote({required int midi, required int startTick, required int durationTicks, Hand hand = Hand.right}) {
    final id = newId('n');
    _edit(() {
      score.notes.add(ScoreNote(
        id: id,
        midi: midi,
        startTick: startTick,
        durationTicks: durationTicks,
        hand: hand,
        staff: hand == Hand.left ? 2 : 1,
        verified: true,
      ));
    });
    return id;
  }

  void verifyNote(String id) => _edit(() {
        final n = note(id);
        if (n != null) _touch(n);
      });

  void verifyMeasure(int index) => _edit(() {
        if (index < 0 || index >= score.measures.length) return;
        final m = score.measures[index];
        m.verified = true;
        m.flags.clear();
        for (final n in score.notes) {
          if (n.measureIndex == index) _touch(n);
        }
      });

  /// Mark the whole score as reviewed. Pedal candidates remain as they are unless verified separately.
  void verifyAll() => _edit(() {
        for (final m in score.measures) {
          m.verified = true;
          m.flags.clear();
        }
        for (final n in score.notes) {
          _touch(n);
        }
        score.review = ReviewState.verified;
      });

  /// Move the barline at the end of measure [index] by [deltaTicks]; later measures shift.
  void adjustMeasureLength(int index, int deltaTicks) => _edit(() {
        if (index < 0 || index >= score.measures.length) return;
        final m = score.measures[index];
        final newLen = m.lengthTicks + deltaTicks;
        if (newLen < kPpq ~/ 8) return;
        m.lengthTicks = newLen;
        m.verified = true;
        for (var i = index + 1; i < score.measures.length; i++) {
          score.measures[i].startTick = score.measures[i - 1].endTick;
        }
      });

  /// Split measure [index] at [tick] into two measures.
  void splitMeasure(int index, int tick) => _edit(() {
        final m = score.measures[index];
        if (tick <= m.startTick || tick >= m.endTick) return;
        final second = Measure(
          index: index + 1,
          startTick: tick,
          lengthTicks: m.endTick - tick,
          number: '${m.number}b',
          time: m.time,
          key: m.key,
          verified: true,
        );
        m.lengthTicks = tick - m.startTick;
        score.measures.insert(index + 1, second);
        _renumber();
      });

  /// Add an empty measure after the last one, using its time and key signature (4/4, C major if none).
  void appendMeasure() => _edit(() {
        final last = score.measures.isEmpty ? null : score.measures.last;
        final time = last?.time ?? const TimeSignature(4, 4);
        final n = int.tryParse(last?.number ?? '');
        score.measures.add(Measure(
          index: score.measures.length,
          startTick: last?.endTick ?? 0,
          lengthTicks: time.measureTicks(kPpq),
          number: n != null ? '${n + 1}' : '${score.measures.length + 1}',
          time: time,
          key: last?.key ?? const KeySignature(0),
          verified: true,
        ));
      });

  void mergeWithNext(int index) => _edit(() {
        if (index + 1 >= score.measures.length) return;
        final m = score.measures[index];
        m.lengthTicks += score.measures[index + 1].lengthTicks;
        score.measures.removeAt(index + 1);
        _renumber();
      });

  void _renumber() {
    for (var i = 0; i < score.measures.length; i++) {
      score.measures[i].index = i;
    }
  }

  /// Change time signature from measure [from] onwards; measure lengths follow.
  void setTimeSignature(int from, TimeSignature ts) => _edit(() {
        for (var i = from; i < score.measures.length; i++) {
          final m = score.measures[i];
          m.time = ts;
          if (!m.pickup) m.lengthTicks = ts.measureTicks(kPpq);
          if (i > 0) m.startTick = score.measures[i - 1].endTick;
        }
      });

  /// Change key signature from measure [from] onwards. Re-spells notes that follow the key (no explicit accidental).
  void setKeySignature(int from, KeySignature key, {bool respellNotes = true}) => _edit(() {
        if (from >= score.measures.length) return;
        final old = score.measures[from].key;
        for (var i = from; i < score.measures.length; i++) {
          score.measures[i].key = key;
        }
        if (!respellNotes) return;
        final startTick = score.measures[from].startTick;
        for (final n in score.notes) {
          if (n.startTick < startTick || n.accidental != null) continue;
          // Find letter step under the old key, re-apply the new key's alteration.
          for (var step = 0; step < 7; step++) {
            final base = Pitch.stepSemitones[step] + old.alterFor(step);
            if ((base - Pitch.pitchClass(n.midi)) % 12 == 0) {
              n.midi += key.alterFor(step) - old.alterFor(step);
              break;
            }
          }
        }
      });

  void setTempo(int tick, double bpm) => _edit(() {
        score.tempos.removeWhere((t) => t.tick == tick);
        score.tempos.add(TempoEvent(tick, bpm.clamp(20, 300)));
      });

  void setRange(int low, int high) => _edit(() {
        score.rangeLow = low;
        score.rangeHigh = high;
      });

  void setTitle(String title, String? composer) => _edit(() {
        score.title = title;
        score.composer = composer;
      });

  // Pedal events are edited independently of notes.
  String addPedal(int tick, PedalType type) {
    final id = newId('p');
    _edit(() {
      score.pedals.add(PedalEvent(id: id, tick: tick, type: type, verified: true, source: 'user'));
      score.pedalDataPresent = true;
    });
    return id;
  }

  void movePedal(String id, int tick) => _edit(() {
        for (final p in score.pedals) {
          if (p.id == id) {
            p.tick = tick < 0 ? 0 : tick;
            p.verified = true;
          }
        }
      });

  void setPedalType(String id, PedalType type) => _edit(() {
        for (final p in score.pedals) {
          if (p.id == id) {
            p.type = type;
            p.verified = true;
          }
        }
      });

  void verifyPedal(String id) => _edit(() {
        for (final p in score.pedals) {
          if (p.id == id) p.verified = true;
        }
      });

  void deletePedal(String id) => _edit(() => score.pedals.removeWhere((p) => p.id == id));
}
