import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../../core/model/pitch.dart';
import '../../core/model/score.dart';
import '../../core/practice/matcher.dart';
import '../theme.dart';

// ---------------------------------------------------------------------------------------------------
// Layout (pure: no BuildContext, no text measurement, no viewport) — unit tested.
// ---------------------------------------------------------------------------------------------------

/// A pitch spelled as letter + alteration + octave for staff placement.
class Spelling {
  final int midi;
  final int step; // 0=C..6=B
  final int alter; // -2..2
  final int octave;

  /// True when the alteration is implied by the key signature (no accidental needed).
  final bool inKey;

  Spelling(this.midi, this.step, this.alter, {required this.inKey})
    : octave = (midi - alter - Pitch.stepSemitones[step]) ~/ 12 - 1;

  /// Diatonic index (C-1 = 0) used for vertical placement.
  int get diatonic => Pitch.diatonicIndex(step, octave);

  static const _symbols = {-2: '𝄫', -1: '♭', 0: '', 1: '♯', 2: '𝄪'};
  static const _spoken = {-2: ' double flat', -1: ' flat', 0: '', 1: ' sharp', 2: ' double sharp'};

  /// Display name such as "E♭4".
  String get label => '${Pitch.stepLetters[step]}${_symbols[alter] ?? ''}$octave';

  /// Screen-reader name such as "E flat 4".
  String get spoken => '${Pitch.stepLetters[step]}${_spoken[alter] ?? ''} $octave';
}

enum StaffHitKind { note, measure, pedal }

/// Result of [StaffLayout.hitTest].
class StaffHit {
  final StaffHitKind kind;
  final String? id;
  final int measureIndex;
  const StaffHit(this.kind, this.measureIndex, [this.id]);
  @override
  String toString() => 'StaffHit($kind, m$measureIndex, $id)';
}

/// One laid-out notehead.
class NoteGlyph {
  final ScoreNote note;
  final Spelling spelling;
  final int staff; // 1 treble, 2 bass
  final int measure;
  final double y;
  final bool showAccidental;
  final int base; // notated value in ticks without dots (1920 whole … 120 sixteenth)
  final int dots;
  final bool uncertain;
  late double x;
  late double accidentalX;
  late bool stemUp;
  bool offset = false;
  List<double> ledgerYs = const [];

  NoteGlyph(
    this.note,
    this.spelling,
    this.staff,
    this.measure,
    this.y, {
    required this.showAccidental,
    required this.base,
    required this.dots,
    required this.uncertain,
  });

  String get id => note.id;
  bool get filled => base <= kPpq;
  int get diatonic => spelling.diatonic;
  bool get onLine => diatonic.isOdd;
}

/// A shared stem for a chord (or single note), with flags.
class StemGlyph {
  final double x, y0, y1;
  final bool up;
  final int flags;
  const StemGlyph(this.x, this.y0, this.y1, this.up, this.flags);
}

class RestGlyph {
  final double x;
  final double staffTop;
  final double voiceShift;
  final int base;
  final int dots;
  final int measure;
  const RestGlyph(this.x, this.staffTop, this.voiceShift, this.base, this.dots, this.measure);
}

/// A tie arc between two noteheads. Drawn as a curve, never in the pedal lane.
class TieGlyph {
  final double x0, x1, y;
  final bool above;
  final int measure;
  const TieGlyph(this.x0, this.x1, this.y, this.above, this.measure);
}

class PedalGlyph {
  final PedalEvent event;
  final double x;
  final Rect rect;
  final bool uncertain;
  final int measure;
  const PedalGlyph(this.event, this.x, this.rect, this.uncertain, this.measure);
  String get id => event.id;
  bool get down => event.type == PedalType.down;
}

/// Bracket line in the pedal lane between a down mark and the following up (or next down).
class PedalSpan {
  final double x0, x1;
  final bool uncertain;
  final bool open;
  const PedalSpan(this.x0, this.x1, this.uncertain, this.open);
}

/// Horizontal extent and attributes of one measure.
class MeasureBox {
  final int index;
  final Measure? measure; // null for the synthetic box used when a score has no measures
  final double x;
  double width = 0;
  final double attrWidth;
  final bool showClef;
  final KeySignature? key; // shown at start when non-null
  final int cancelFifths; // naturals to draw when changing to C major / A minor
  final TimeSignature? time;
  final bool uncertain;
  final List<int> colTicks = [];
  final List<double> colXs = [];
  final List<NoteGlyph> notes = [];
  final List<StemGlyph> stems = [];
  final List<RestGlyph> rests = [];
  final List<TieGlyph> ties = [];

  MeasureBox(
    this.index,
    this.measure,
    this.x,
    this.attrWidth, {
    required this.showClef,
    this.key,
    this.cancelFifths = 0,
    this.time,
    this.uncertain = false,
  });

  double get right => x + width;
  bool get selectable => measure != null;
}

/// Pure geometry for a horizontally scrolling grand staff. All coordinates are content pixels with
/// the origin at the top-left of the [StaffView].
class StaffLayout {
  final Score score;
  final double scale;
  final int transpose;
  final bool showPedal;
  final bool noteNames;

  /// Staff space (distance between two staff lines).
  final double s;
  late final double headerH, trebleTop, bassTop, pedalTop, height, leftMargin, headW, width;
  final List<MeasureBox> measures = [];
  final List<NoteGlyph> notes = [];
  final Map<String, NoteGlyph> byId = {};
  final List<PedalGlyph> pedals = [];
  final List<PedalSpan> pedalSpans = [];

  static const uncertainThreshold = 0.75;

  StaffLayout(this.score, {this.scale = 1.0, this.transpose = 0, this.showPedal = true, this.noteNames = false})
    : s = 10 * scale {
    headerH = 3.2 * s;
    leftMargin = 2.4 * s;
    headW = (noteNames ? 1.75 : 1.3) * s;
    _build();
    width = (measures.isEmpty ? leftMargin + 12 * s : measures.last.right) + 3 * s;
  }

  double get trebleBottom => trebleTop + 4 * s;
  double get bassBottom => bassTop + 4 * s;
  double get pedalMid => pedalTop + 1.4 * s;
  double staffTop(int staff) => staff == 2 ? bassTop : trebleTop;
  double get clefWidth => 3.6 * s;
  double keyWidth(int count) => count == 0 ? 0 : count * 1.0 * s + 0.6 * s;

  /// Vertical position of a diatonic index on a staff (top line treble = F5, bass = A3).
  double yFor(int staff, int diatonic) =>
      staff == 2 ? bassTop + (33 - diatonic) * s / 2 : trebleTop + (45 - diatonic) * s / 2;

  /// Diatonic indices of ledger lines needed for a note.
  static List<int> ledgerLines(int staff, int diatonic) {
    final top = staff == 2 ? 33 : 45, bottom = staff == 2 ? 25 : 37;
    return [for (var d = top + 2; d <= diatonic; d += 2) d, for (var d = bottom - 2; d >= diatonic; d -= 2) d];
  }

  /// Spell [midi] in [key]: key-signature letters first, then sharps (or flats in flat keys).
  /// An explicit [accidental] (-2..2) fixes the letter.
  static Spelling spell(int midi, KeySignature key, {int? accidental}) {
    final pc = midi % 12;
    if (accidental != null && accidental.abs() <= 2) {
      final step = Pitch.stepSemitones.indexOf((pc - accidental) % 12);
      if (step >= 0) return Spelling(midi, step, accidental, inKey: key.alterFor(step) == accidental);
    }
    for (var step = 0; step < 7; step++) {
      final a = key.alterFor(step);
      if ((Pitch.stepSemitones[step] + a) % 12 == pc) return Spelling(midi, step, a, inKey: true);
    }
    final white = Pitch.stepSemitones.indexOf(pc);
    if (white >= 0) return Spelling(midi, white, 0, inKey: false);
    final flats = key.prefersFlats;
    final step = Pitch.stepSemitones.indexOf(flats ? (pc + 1) % 12 : pc - 1);
    return Spelling(midi, step, flats ? -1 : 1, inKey: false);
  }

  /// Key signature shown when the display is transposed by [semitones].
  static KeySignature displayKey(KeySignature k, int semitones) {
    if (semitones == 0) return k;
    final f = ((k.fifths + 7 * semitones + 6) % 12 + 12) % 12 - 6;
    return KeySignature(f, minor: k.minor);
  }

  /// Notated value (ticks without dots) and dot count for a written duration.
  static (int, int) noteValue(int ticks, int dots) {
    const bases = [1920, 960, 480, 240, 120, 60, 30];
    if (dots > 0) {
      final undotted = ticks / (dots == 1 ? 1.5 : 1.75);
      var best = bases.first;
      for (final b in bases) {
        if ((b - undotted).abs() < (best - undotted).abs()) best = b;
      }
      return (best, dots);
    }
    for (final b in bases) {
      if (ticks == b) return (b, 0);
      if (ticks * 2 == b * 3) return (b, 1);
    }
    for (final b in bases) {
      if (ticks >= b) return (b, 0);
    }
    return (30, 0);
  }

  static int flagCount(int base) => switch (base) {
    240 => 1,
    120 => 2,
    60 => 3,
    30 => 4,
    _ => 0,
  };

  static bool isUncertainNote(ScoreNote n) => !n.verified && (n.confidence < uncertainThreshold || n.flags.isNotEmpty);
  static bool isUncertainMeasure(Measure m) => !m.verified && (m.confidence < uncertainThreshold || m.flags.isNotEmpty);
  static bool isUncertainPedal(PedalEvent p) => !p.verified && p.confidence < uncertainThreshold;

  final Map<ScoreNote, Spelling> _spellings = Map.identity();

  int _staffOf(ScoreNote n) => n.staff == 1 || n.staff == 2 ? n.staff : (n.midi >= 60 ? 1 : 2);

  void _build() {
    final src = score.measures;
    final ms = src.isNotEmpty
        ? src
        : [
            if (score.notes.isNotEmpty || score.rests.isNotEmpty)
              Measure(
                index: 0,
                startTick: 0,
                lengthTicks: math.max(score.endTick, 1),
                number: '',
                time: const TimeSignature(4, 4),
                key: const KeySignature(0),
              ),
          ];
    final notesBy = List.generate(ms.length, (_) => <ScoreNote>[]);
    final restsBy = List.generate(ms.length, (_) => <ScoreRest>[]);
    int indexAt(int tick) {
      var lo = 0, hi = ms.length - 1;
      while (lo < hi) {
        final mid = (lo + hi + 1) >> 1;
        if (ms[mid].startTick <= tick) {
          lo = mid;
        } else {
          hi = mid - 1;
        }
      }
      return lo;
    }

    if (ms.isNotEmpty) {
      for (final n in score.notes) {
        notesBy[indexAt(n.startTick)].add(n);
      }
      for (final r in score.rests) {
        restsBy[indexAt(r.startTick)].add(r);
      }
    }

    // Spell first so the vertical room can grow to fit the actual range (MIDI has no 8va).
    var hi1 = 45, lo1 = 37, hi2 = 33, lo2 = 25;
    for (var i = 0; i < ms.length; i++) {
      final key = displayKey(ms[i].key, transpose);
      for (final n in notesBy[i]) {
        final sp = spell((n.midi + transpose).clamp(0, 127), key, accidental: transpose == 0 ? n.accidental : null);
        _spellings[n] = sp;
        final d = sp.diatonic;
        if (_staffOf(n) == 1) {
          hi1 = math.max(hi1, d);
          lo1 = math.min(lo1, d);
        } else {
          hi2 = math.max(hi2, d);
          lo2 = math.min(lo2, d);
        }
      }
    }
    final half = s / 2;
    trebleTop = headerH + math.max(3.5 * s, (hi1 - 45) * half + 2.2 * s);
    final gap = math.max(5.5 * s, (37 - lo1) * half + (hi2 - 33) * half + 2.5 * s);
    bassTop = trebleTop + 4 * s + gap;
    pedalTop = bassTop + 4 * s + math.max(3.5 * s, (25 - lo2) * half + 2.8 * s);
    height = showPedal ? pedalTop + 3.4 * s : pedalTop;

    var x = leftMargin;
    KeySignature? prevKey;
    TimeSignature? prevTime;
    for (var i = 0; i < ms.length; i++) {
      final m = ms[i];
      final key = displayKey(m.key, transpose);
      final showClef = i == 0;
      final keyChanged = prevKey == null ? key.fifths != 0 : key.fifths != prevKey.fifths;
      final cancel = keyChanged && key.fifths == 0 && prevKey != null ? prevKey.fifths : 0;
      final showTime = prevTime == null || m.time != prevTime;
      var attr =
          (showClef ? clefWidth : 0.0) +
          (keyChanged ? keyWidth(cancel != 0 ? cancel.abs() : key.fifths.abs()) : 0.0) +
          (showTime ? 2.6 * s : 0.0);
      if (attr > 0) attr += 0.4 * s;
      final box = MeasureBox(
        i,
        src.isEmpty ? null : m,
        x,
        attr,
        showClef: showClef,
        key: keyChanged ? key : null,
        cancelFifths: cancel,
        time: showTime ? m.time : null,
        uncertain: src.isNotEmpty && isUncertainMeasure(m),
      );
      _layoutMeasure(box, m, key, notesBy[i], restsBy[i]);
      measures.add(box);
      x = box.right;
      prevKey = key;
      prevTime = m.time;
    }
    _layoutTies();
    if (showPedal) _layoutPedals();
  }

  void _layoutMeasure(MeasureBox box, Measure m, KeySignature key, List<ScoreNote> mNotes, List<ScoreRest> mRests) {
    // 1. Place vertically. Accidentals: out-of-key or explicit ones always show; an alteration that
    // differs from what is in effect earlier in the measure (same staff and line) shows too.
    final glyphs = <NoteGlyph>[];
    final inEffect = <int, int>{};
    for (final n in [...mNotes]..sort((a, b) => a.startTick.compareTo(b.startTick))) {
      final staff = _staffOf(n);
      final written = transpose == 0 ? n.accidental : null;
      final sp = _spellings[n] ?? spell((n.midi + transpose).clamp(0, 127), key, accidental: written);
      final slot = staff * 1000 + sp.diatonic;
      final carried = inEffect[slot] ?? key.alterFor(sp.step);
      inEffect[slot] = sp.alter;
      final (base, dots) = noteValue(n.durationTicks, n.dots);
      final g = NoteGlyph(
        n,
        sp,
        staff,
        box.index,
        yFor(staff, sp.diatonic),
        showAccidental: !sp.inKey || written != null || carried != sp.alter,
        base: base,
        dots: dots,
        uncertain: isUncertainNote(n),
      );
      g.ledgerYs = [for (final d in ledgerLines(staff, sp.diatonic)) yFor(staff, d)];
      glyphs.add(g);
    }

    // 2. Chords: same staff, voice and start share a stem.
    final chords = <String, List<NoteGlyph>>{};
    final voices = <int, Set<int>>{};
    for (final g in glyphs) {
      chords.putIfAbsent('${g.staff}:${g.note.voice}:${g.note.startTick}', () => []).add(g);
      voices.putIfAbsent(g.staff, () => {}).add(g.note.voice);
    }
    final leftPad = <int, double>{}, rightPad = <int, double>{};
    for (final chord in chords.values) {
      final first = chord.first;
      final multi = (voices[first.staff]?.length ?? 1) > 1;
      final middle = first.staff == 2 ? 29 : 41;
      final lo = chord.map((g) => g.diatonic).reduce(math.min), hi = chord.map((g) => g.diatonic).reduce(math.max);
      final up = multi ? first.note.voice.isOdd : (lo + hi) / 2 < middle;
      for (final g in chord) {
        g.stemUp = up;
      }
      // Seconds: the second head of an adjacent pair moves to the other side of the stem.
      final ordered = [...chord]..sort((a, b) => up ? a.diatonic - b.diatonic : b.diatonic - a.diatonic);
      for (var k = 1; k < ordered.length; k++) {
        if ((ordered[k].diatonic - ordered[k - 1].diatonic).abs() == 1 && !ordered[k - 1].offset) {
          ordered[k].offset = true;
        }
      }
      final t = first.note.startTick;
      final accCount = chord.where((g) => g.showAccidental).length;
      var pre = accCount == 0 ? 0.0 : 1.5 * s + (accCount > 1 ? 1.1 * s : 0);
      if (!up && chord.any((g) => g.offset)) pre += headW;
      leftPad[t] = math.max(leftPad[t] ?? 0, pre);
      var post = chord.any((g) => g.dots > 0) ? 0.9 * s : 0.0;
      if (up && chord.any((g) => g.offset)) post += headW;
      if (up && flagCount(first.base) > 0) post += 0.6 * s;
      rightPad[t] = math.max(rightPad[t] ?? 0, post);
    }

    // 3. Columns: one per distinct onset, spaced by the time to the next onset.
    final onsets = <int>{m.startTick, ...mNotes.map((n) => n.startTick), ...mRests.map((r) => r.startTick)}.toList()
      ..sort();
    final endTick = math.max(m.endTick, onsets.last + 1);
    final colX = <int, double>{};
    var cx = box.x + box.attrWidth + 0.9 * s;
    for (var j = 0; j < onsets.length; j++) {
      final t = onsets[j];
      final gap = (j + 1 < onsets.length ? onsets[j + 1] : endTick) - t;
      final x = cx + (leftPad[t] ?? 0) + headW / 2;
      colX[t] = x;
      box.colTicks.add(t);
      box.colXs.add(x);
      cx = x + headW / 2 + (rightPad[t] ?? 0) + s * (0.9 + 2.3 * math.sqrt(gap / kPpq));
    }
    box.width = math.max(cx + 0.3 * s, box.x + box.attrWidth + 7 * s) - box.x;
    box.colTicks.add(endTick);
    box.colXs.add(box.right);

    // 4. Horizontal placement, stems, accidentals.
    for (final chord in chords.values) {
      final first = chord.first;
      final cxHead = colX[first.note.startTick]!;
      final up = first.stemUp;
      final accs = chord.where((g) => g.showAccidental).toList()..sort((a, b) => b.diatonic - a.diatonic);
      final leftmost = cxHead - headW / 2 - (!up && chord.any((g) => g.offset) ? headW : 0);
      for (final g in chord) {
        g.x = cxHead + (g.offset ? (up ? headW * 0.95 : -headW * 0.95) : 0);
      }
      for (var k = 0; k < accs.length; k++) {
        accs[k].accidentalX = leftmost - 0.85 * s - (accs.length > 1 && k.isOdd ? 1.1 * s : 0);
      }
      if (first.base <= 960) {
        final ys = chord.map((g) => g.y);
        final top = ys.reduce(math.min), bottom = ys.reduce(math.max);
        final middleY = staffTop(first.staff) + 2 * s;
        final flags = flagCount(first.base);
        final len = 3.5 * s + (flags > 1 ? flags - 1 : 0) * 0.8 * s;
        final sx = up ? cxHead + headW / 2 - 0.06 * s : cxHead - headW / 2 + 0.06 * s;
        box.stems.add(
          up
              ? StemGlyph(sx, bottom, math.min(top - len, middleY), true, flags)
              : StemGlyph(sx, top, math.max(bottom + len, middleY), false, flags),
        );
      }
    }
    glyphs.sort((a, b) => a.x.compareTo(b.x));
    box.notes.addAll(glyphs);
    notes.addAll(glyphs);
    for (final g in glyphs) {
      byId[g.id] = g;
    }

    final restVoices = <int, Set<int>>{};
    for (final r in mRests) {
      restVoices.putIfAbsent(r.staff, () => {}).add(r.voice);
    }
    for (final r in mRests) {
      final staff = r.staff == 2 ? 2 : 1;
      final multi = ((voices[staff]?.length ?? 0) > 1) || ((restVoices[staff]?.length ?? 0) > 1);
      final shift = multi ? (r.voice.isOdd ? -1.5 * s : 1.5 * s) : 0.0;
      final (base, dots) = noteValue(r.durationTicks, 0);
      box.rests.add(RestGlyph(colX[r.startTick]!, staffTop(staff), shift, base, dots, box.index));
    }
  }

  void _layoutTies() {
    final sorted = [...notes]..sort((a, b) => a.note.startTick.compareTo(b.note.startTick));
    for (var i = 0; i < sorted.length; i++) {
      final a = sorted[i];
      if (!a.note.tieStart) continue;
      NoteGlyph? b;
      for (var j = i + 1; j < sorted.length; j++) {
        final c = sorted[j];
        if (c.note.startTick > a.note.startTick && c.note.midi == a.note.midi && c.staff == a.staff && c.note.tieStop) {
          b = c;
          break;
        }
      }
      final above = !a.stemUp;
      final y = a.y + (above ? -0.75 * s : 0.75 * s);
      final x0 = a.x + headW * 0.55;
      final x1 = b == null ? x0 + 2.5 * s : b.x - headW * 0.55;
      if (x1 > x0) measures[a.measure].ties.add(TieGlyph(x0, x1, y, above, a.measure));
    }
  }

  void _layoutPedals() {
    final sorted = [...score.pedals]..sort((a, b) => a.tick.compareTo(b.tick));
    PedalGlyph? open;
    // A release immediately followed by a press (a pedal change) would draw "✱" on top of "Ped.";
    // pull the release left and push the press right so both stay readable and tappable.
    final change = 2.6 * s;
    double rawX(int i) => xForTick(sorted[i].tick.toDouble());
    for (var i = 0; i < sorted.length; i++) {
      final p = sorted[i];
      final down = p.type == PedalType.down;
      var x = rawX(i);
      if (!down && i + 1 < sorted.length && sorted[i + 1].type == PedalType.down && rawX(i + 1) - x < change) {
        x -= 1.3 * s;
      } else if (down && i > 0 && sorted[i - 1].type == PedalType.up && x - rawX(i - 1) < change) {
        x += 0.9 * s;
      }
      final rect = down
          ? Rect.fromLTWH(x - 0.3 * s, pedalTop, 3.0 * s, 2.8 * s)
          : Rect.fromCenter(center: Offset(x, pedalMid), width: 2.4 * s, height: 2.4 * s);
      final g = PedalGlyph(p, x, rect, isUncertainPedal(p), measureIndexAtX(x));
      if (open != null) {
        final x1 = down ? x - 0.5 * s : x - 1.0 * s;
        if (x1 > open.rect.right) pedalSpans.add(PedalSpan(open.rect.right, x1, open.uncertain || g.uncertain, false));
        open = null;
      }
      if (down) open = g;
      pedals.add(g);
    }
    if (open != null && measures.isNotEmpty) {
      pedalSpans.add(PedalSpan(open.rect.right, measures.last.right - 0.4 * s, open.uncertain, true));
    }
  }

  /// Horizontal position for a (fractional) tick, interpolated between note columns.
  double xForTick(double tick) {
    if (measures.isEmpty) return leftMargin;
    var lo = 0, hi = measures.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (measures[mid].colTicks.first <= tick) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    final b = measures[lo];
    final ts = b.colTicks, xs = b.colXs;
    if (tick <= ts.first) return lo == 0 ? xs.first : b.x + b.attrWidth;
    for (var k = 1; k < ts.length; k++) {
      if (tick <= ts[k]) {
        final f = (tick - ts[k - 1]) / (ts[k] - ts[k - 1]);
        return xs[k - 1] + (xs[k] - xs[k - 1]) * f;
      }
    }
    return b.right;
  }

  /// Index into [measures] of the box containing content x (clamped).
  int measureIndexAtX(double x) {
    if (measures.isEmpty) return 0;
    var lo = 0, hi = measures.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (measures[mid].x <= x) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  /// Header (measure number) tap area for a measure, at least 48 px tall.
  Rect headerRect(MeasureBox b) => Rect.fromLTWH(b.x, 0, b.width, math.max(headerH, 48));

  /// Finds what is under [p]: pedal marks in the lane, then the nearest notehead within a
  /// finger-sized radius, then the measure (header or empty staff area).
  StaffHit? hitTest(Offset p) {
    if (measures.isEmpty || p.dx < 0 || p.dx > width || p.dy < 0 || p.dy > height) return null;
    final mi = measureIndexAtX(p.dx);
    final box = measures[mi];
    if (showPedal && p.dy >= pedalTop - 0.6 * s) {
      PedalGlyph? best;
      var bestD = math.max(2.4 * s, 24.0);
      for (final g in pedals) {
        final d = (g.rect.center.dx - p.dx).abs();
        if (d < bestD || g.rect.inflate(4).contains(p)) {
          best = g;
          bestD = math.min(d, bestD);
        }
      }
      if (best != null) return StaffHit(StaffHitKind.pedal, best.measure, best.id);
      return box.selectable ? StaffHit(StaffHitKind.measure, mi) : null;
    }
    if (p.dy > headerH) {
      NoteGlyph? best;
      final r = math.max(2.4 * s, 24.0);
      var bestD = r * r;
      for (var k = math.max(0, mi - 1); k <= math.min(measures.length - 1, mi + 1); k++) {
        for (final g in measures[k].notes) {
          final dx = g.x - p.dx, dy = g.y - p.dy;
          final d = dx * dx + dy * dy;
          if (d < bestD) {
            bestD = d;
            best = g;
          }
        }
      }
      if (best != null) return StaffHit(StaffHitKind.note, best.measure, best.id);
    }
    return box.selectable ? StaffHit(StaffHitKind.measure, mi) : null;
  }

  static String valueName(int base) => switch (base) {
    >= 1920 => 'whole',
    960 => 'half',
    480 => 'quarter',
    240 => 'eighth',
    120 => 'sixteenth',
    60 => '32nd',
    _ => 'short',
  };

  /// Screen-reader description of a notehead.
  String describe(NoteGlyph g) {
    final n = g.note;
    final hand = switch (n.hand) {
      Hand.right => ', right hand',
      Hand.left => ', left hand',
      Hand.unassigned => '',
    };
    final dotted = g.dots > 0 ? 'dotted ' : '';
    final num = measures[g.measure].measure?.number ?? '${g.measure + 1}';
    final tie = n.tieStart ? ', tied to next' : '';
    return '${g.spelling.spoken}, $dotted${valueName(g.base)} note$hand$tie, measure $num';
  }
}

// ---------------------------------------------------------------------------------------------------
// Widget
// ---------------------------------------------------------------------------------------------------

/// Horizontally scrolling grand-staff notation. Shared by the review editor and practice sheet view.
class StaffView extends StatefulWidget {
  const StaffView({
    super.key,
    required this.score,
    this.selectedNoteId,
    this.selectedMeasure,
    this.onNoteTap,
    this.onMeasureTap,
    this.onPedalTap,
    this.cursorTick,
    this.highlightMeasure,
    this.outcomes,
    this.showPedal = true,
    this.noteNames = false,
    this.showFingers = true,
    this.showConfidence = true,
    this.transpose = 0,
    this.scale = 1.0,
    this.selectedPedalId,
  });

  final Score score;
  final String? selectedNoteId;
  final int? selectedMeasure;
  final void Function(String noteId)? onNoteTap;
  final void Function(int measureIndex)? onMeasureTap;
  final void Function(String pedalId)? onPedalTap;

  /// Playback cursor; when set the view follows it.
  final double? cursorTick;
  final int? highlightMeasure;
  final Map<String, NoteOutcome>? outcomes;
  final bool showPedal;
  final bool noteNames;
  final bool showFingers;
  final bool showConfidence;
  final int transpose;
  final double scale;

  /// Highlights a pedal mark (review editor).
  final String? selectedPedalId;

  @override
  State<StaffView> createState() => _StaffViewState();
}

class _StaffViewState extends State<StaffView> {
  final _scroll = ScrollController();
  StaffLayout? _layout;
  int? _sig;
  double _viewportW = 0;
  (int, int) _visible = (0, 0);

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback(
        (_) => widget.cursorTick != null ? _followCursor() : _ensureSelectionVisible(animate: false));
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  int _signature() {
    final sc = widget.score;
    return Object.hash(
      identityHashCode(sc),
      widget.scale,
      widget.transpose,
      widget.showPedal,
      widget.noteNames,
      Object.hashAll([
        for (final n in sc.notes)
          Object.hash(
            n.id,
            n.midi,
            n.startTick,
            n.durationTicks,
            n.staff,
            n.voice,
            n.dots,
            n.accidental,
            n.tieStart,
            n.tieStop,
            n.verified,
            n.confidence,
            n.flags.length,
            n.hand,
            n.finger,
          ),
      ]),
      Object.hashAll([
        for (final m in sc.measures)
          Object.hash(m.startTick, m.lengthTicks, m.number, m.time, m.key, m.verified, m.confidence, m.flags.length),
      ]),
      Object.hashAll([for (final p in sc.pedals) Object.hash(p.id, p.tick, p.type, p.verified, p.confidence)]),
      Object.hashAll([for (final r in sc.rests) Object.hash(r.startTick, r.durationTicks, r.staff, r.voice)]),
    );
  }

  /// Rebuilds the layout when content changed. Called from build only; handlers use the cached [_l].
  StaffLayout _layoutForBuild() {
    final sig = _signature();
    if (_layout == null || sig != _sig) {
      _layout = StaffLayout(
        widget.score,
        scale: widget.scale,
        transpose: widget.transpose,
        showPedal: widget.showPedal,
        noteNames: widget.noteNames,
      );
      _sig = sig;
    }
    return _layout!;
  }

  StaffLayout get _l => _layout ?? _layoutForBuild();

  (int, int) _visibleRange() {
    final l = _l;
    final off = _scroll.hasClients ? _scroll.offset : 0.0;
    return (l.measureIndexAtX(off), l.measureIndexAtX(off + _viewportW));
  }

  void _onScroll() {
    final v = _visibleRange();
    if (v != _visible) setState(() => _visible = v);
  }

  @override
  void didUpdateWidget(StaffView old) {
    super.didUpdateWidget(old);
    if (widget.cursorTick != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _followCursor());
    } else if (old.selectedNoteId != widget.selectedNoteId ||
        old.selectedMeasure != widget.selectedMeasure ||
        old.selectedPedalId != widget.selectedPedalId ||
        old.highlightMeasure != widget.highlightMeasure) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _ensureSelectionVisible());
    }
  }

  void _followCursor() {
    final t = widget.cursorTick;
    if (!mounted || t == null || !_scroll.hasClients) return;
    final target = (_l.xForTick(t) - _viewportW * 0.3).clamp(0.0, _scroll.position.maxScrollExtent);
    if ((target - _scroll.offset).abs() > 0.5) _scroll.jumpTo(target);
  }

  void _ensureSelectionVisible({bool animate = true}) {
    if (!mounted || !_scroll.hasClients) return;
    final l = _l;
    double? x;
    final note = widget.selectedNoteId == null ? null : l.byId[widget.selectedNoteId];
    if (note != null) {
      x = note.x;
    } else if (widget.selectedPedalId != null) {
      for (final p in l.pedals) {
        if (p.id == widget.selectedPedalId) x = p.x;
      }
    }
    final mi = widget.selectedMeasure ?? widget.highlightMeasure;
    if (x == null && mi != null && mi >= 0 && mi < l.measures.length) {
      final b = l.measures[mi];
      x = b.x + math.min(b.width, _viewportW * 0.8) / 2;
    }
    if (x == null) return;
    final off = _scroll.offset;
    if (x > off + 2 * l.s && x < off + _viewportW - 2 * l.s) return;
    final target = (x - _viewportW * 0.4).clamp(0.0, _scroll.position.maxScrollExtent);
    if (animate) {
      _scroll.animateTo(target, duration: const Duration(milliseconds: 300), curve: Curves.easeOutCubic);
    } else {
      _scroll.jumpTo(target);
    }
  }

  void _tap(Offset p) {
    final hit = _l.hitTest(p);
    if (hit == null) return;
    switch (hit.kind) {
      case StaffHitKind.note when widget.onNoteTap != null:
        widget.onNoteTap!(hit.id!);
      case StaffHitKind.pedal when widget.onPedalTap != null:
        widget.onPedalTap!(hit.id!);
      default:
        if (hit.measureIndex < widget.score.measures.length) widget.onMeasureTap?.call(hit.measureIndex);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, c) {
        final l = _layoutForBuild();
        _viewportW = c.hasBoundedWidth ? c.maxWidth : l.width;
        final w = math.max(l.width, _viewportW);
        if (_scroll.hasClients) _visible = _visibleRange();
        final painter = _StaffPainter(
          layout: l,
          palette: _StaffPalette.of(theme),
          textStyle: DefaultTextStyle.of(context).style,
          scroll: _scroll,
          viewportWidth: _viewportW,
          visible: _scroll.hasClients ? _visible : (0, l.measureIndexAtX(_viewportW)),
          selectedNoteId: widget.selectedNoteId,
          selectedMeasure: widget.selectedMeasure,
          selectedPedalId: widget.selectedPedalId,
          highlightMeasure: widget.highlightMeasure,
          cursorTick: widget.cursorTick,
          outcomes: widget.outcomes,
          showFingers: widget.showFingers,
          showConfidence: widget.showConfidence,
          omr: widget.score.origin == ScoreOrigin.omr,
          onNoteTap: widget.onNoteTap,
          onMeasureTap: widget.onMeasureTap,
          onPedalTap: widget.onPedalTap,
        );
        // Keep this structure stable: swapping wrappers would briefly attach the controller twice.
        final fits = !c.hasBoundedHeight || c.maxHeight >= l.height;
        final view = SingleChildScrollView(
          primary: false,
          physics: fits ? const NeverScrollableScrollPhysics() : null,
          child: SizedBox(
            height: l.height,
            child: Scrollbar(
              controller: _scroll,
              child: SingleChildScrollView(
                controller: _scroll,
                scrollDirection: Axis.horizontal,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (d) => _tap(d.localPosition),
                  child: CustomPaint(size: Size(w, l.height), painter: painter),
                ),
              ),
            ),
          ),
        );
        final t = widget.transpose;
        return Stack(
          children: [
            view,
            if (t != 0)
              Positioned(
                top: 4,
                right: 8,
                child: Semantics(
                  label: 'Display transposed ${t > 0 ? 'up' : 'down'} ${t.abs()} semitones',
                  excludeSemantics: true,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.secondaryContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      'Transposed ${t > 0 ? '+' : '−'}${t.abs()}',
                      style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSecondaryContainer),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------------------------------
// Painting
// ---------------------------------------------------------------------------------------------------

class _StaffPalette {
  final Color ink, line, recognized, selection, measureSel, highlight, uncertainFill, cursor, background;
  const _StaffPalette(
    this.ink,
    this.line,
    this.recognized,
    this.selection,
    this.measureSel,
    this.highlight,
    this.uncertainFill,
    this.cursor,
    this.background,
  );

  factory _StaffPalette.of(ThemeData t) {
    final c = t.colorScheme;
    return _StaffPalette(
      c.onSurface,
      c.onSurface.withValues(alpha: 0.55),
      Color.lerp(c.onSurface, c.primary, 0.45)!,
      c.primary,
      c.primary.withValues(alpha: 0.12),
      SlColors.brass.withValues(alpha: 0.16),
      SlColors.warn.withValues(alpha: 0.10),
      SlColors.brass,
      t.scaffoldBackgroundColor,
    );
  }
}

final Map<String, TextPainter> _textCache = {};

TextPainter _text(String s, TextStyle style) {
  final key = '$s|${style.fontSize}|${style.color?.toARGB32()}|${style.fontWeight}|${style.fontStyle}';
  final hit = _textCache[key];
  if (hit != null) return hit;
  if (_textCache.length > 500) {
    for (final tp in _textCache.values) {
      tp.dispose();
    }
    _textCache.clear();
  }
  return _textCache[key] = TextPainter(
    text: TextSpan(text: s, style: style),
    textDirection: TextDirection.ltr,
  )..layout();
}

class _StaffPainter extends CustomPainter {
  final StaffLayout layout;
  final _StaffPalette palette;
  final TextStyle textStyle;
  final ScrollController scroll;
  final double viewportWidth;
  final (int, int) visible;
  final String? selectedNoteId;
  final int? selectedMeasure;
  final String? selectedPedalId;
  final int? highlightMeasure;
  final double? cursorTick;
  final Map<String, NoteOutcome>? outcomes;
  final bool showFingers, showConfidence, omr;
  final void Function(String)? onNoteTap;
  final void Function(int)? onMeasureTap;
  final void Function(String)? onPedalTap;

  _StaffPainter({
    required this.layout,
    required this.palette,
    required this.textStyle,
    required this.scroll,
    required this.viewportWidth,
    required this.visible,
    required this.selectedNoteId,
    required this.selectedMeasure,
    required this.selectedPedalId,
    required this.highlightMeasure,
    required this.cursorTick,
    required this.outcomes,
    required this.showFingers,
    required this.showConfidence,
    required this.omr,
    required this.onNoteTap,
    required this.onMeasureTap,
    required this.onPedalTap,
  }) : super(repaint: scroll);

  double get s => layout.s;

  Paint _stroke(Color c, double w) => Paint()
    ..color = c
    ..style = PaintingStyle.stroke
    ..strokeWidth = w
    ..strokeCap = StrokeCap.round
    ..isAntiAlias = true;
  Paint _fill(Color c) => Paint()..color = c;

  TextStyle _ts(double size, Color color, {FontWeight? weight, FontStyle? style}) =>
      textStyle.copyWith(fontSize: size, color: color, fontWeight: weight, fontStyle: style, height: 1.0);

  void _drawText(Canvas canvas, String t, Offset center, TextStyle style) {
    final tp = _text(t, style);
    tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  void paint(Canvas canvas, Size size) {
    final off = scroll.hasClients ? scroll.offset : 0.0;
    final vw = viewportWidth <= 0 ? size.width : viewportWidth;
    final left = off - 4 * s, right = off + vw + 4 * s;
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(math.max(0, off), 0, off + vw, size.height));
    final l = layout;
    final first = l.measureIndexAtX(left), last = l.measureIndexAtX(right);

    if (l.measures.isNotEmpty) {
      for (var i = first; i <= last; i++) {
        _measureBackground(canvas, l.measures[i]);
      }
    }
    _staffLines(canvas, math.max(left, l.leftMargin), math.min(right, size.width - 2 * s));
    if (left < l.leftMargin + 2 * s) _systemStart(canvas);
    if (l.measures.isNotEmpty) {
      for (var i = first; i <= last; i++) {
        _measure(canvas, l.measures[i], last: i == l.measures.length - 1);
      }
      for (var i = math.max(0, first - 1); i <= last; i++) {
        final b = l.measures[i];
        for (final t in b.ties) {
          _tie(canvas, t);
        }
      }
      for (var i = first; i <= last; i++) {
        final b = l.measures[i];
        for (final r in b.rests) {
          _rest(canvas, r);
        }
        for (final st in b.stems) {
          _stem(canvas, st);
        }
        for (final g in b.notes) {
          _note(canvas, g);
        }
      }
    }
    if (l.showPedal) _pedalLane(canvas, left, right);
    if (off > l.leftMargin + l.clefWidth) _stickyHeader(canvas, off);
    if (cursorTick != null && l.measures.isNotEmpty) {
      final x = l.xForTick(cursorTick!);
      final p = _stroke(palette.cursor, math.max(2, 0.25 * s));
      canvas.drawLine(
        Offset(x, l.trebleTop - 2.5 * s),
        Offset(x, (l.showPedal ? l.pedalTop + 2.8 * s : l.bassBottom + 2.5 * s)),
        p,
      );
    }
    canvas.restore();
  }

  // ---- Staff frame ----

  void _staffLines(Canvas canvas, double x0, double x1) {
    if (x1 <= x0) return;
    final p = _stroke(palette.line, math.max(1, 0.1 * s))..strokeCap = StrokeCap.butt;
    for (final top in [layout.trebleTop, layout.bassTop]) {
      for (var k = 0; k < 5; k++) {
        canvas.drawLine(Offset(x0, top + k * s), Offset(x1, top + k * s), p);
      }
    }
  }

  void _systemStart(Canvas canvas) {
    final l = layout;
    final x = l.leftMargin;
    canvas.drawLine(Offset(x, l.trebleTop), Offset(x, l.bassBottom), _stroke(palette.ink, math.max(1.2, 0.14 * s)));
    _brace(canvas, x - 0.6 * s, l.trebleTop, l.bassBottom);
  }

  void _brace(Canvas canvas, double x, double top, double bottom) {
    final mid = (top + bottom) / 2, w = 0.9 * s;
    final path = Path()
      ..moveTo(x, top)
      ..cubicTo(x - w, top + 0.15 * (bottom - top), x, mid - 0.15 * (bottom - top), x - w, mid)
      ..cubicTo(x, mid + 0.15 * (bottom - top), x - w, bottom - 0.15 * (bottom - top), x, bottom);
    canvas.drawPath(path, _stroke(palette.ink, 0.28 * s));
  }

  void _measureBackground(Canvas canvas, MeasureBox b) {
    final l = layout;
    final rect = Rect.fromLTRB(b.x, l.trebleTop - 2.5 * s, b.right, l.bassBottom + 2.5 * s);
    if (b.index == selectedMeasure) {
      canvas.drawRRect(RRect.fromRectAndRadius(rect, Radius.circular(s * 0.6)), _fill(palette.measureSel));
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect.deflate(1), Radius.circular(s * 0.6)),
        _stroke(palette.selection, 2),
      );
    } else if (b.index == highlightMeasure) {
      canvas.drawRRect(RRect.fromRectAndRadius(rect, Radius.circular(s * 0.6)), _fill(palette.highlight));
    }
    if (showConfidence && b.uncertain) {
      final r = rect.deflate(3);
      canvas.drawRect(r, _fill(palette.uncertainFill));
      canvas.drawPath(
        _dashed(Path()..addRRect(RRect.fromRectAndRadius(r, Radius.circular(s * 0.5))), 0.6 * s, 0.4 * s),
        _stroke(SlColors.warn, math.max(1.2, 0.14 * s)),
      );
    }
  }

  void _measure(Canvas canvas, MeasureBox b, {required bool last}) {
    final l = layout;
    // Barline at the end of the measure.
    final bar = _stroke(palette.ink, math.max(1, 0.12 * s))..strokeCap = StrokeCap.butt;
    if (last) {
      canvas.drawLine(Offset(b.right - 0.6 * s, l.trebleTop), Offset(b.right - 0.6 * s, l.bassBottom), bar);
      canvas.drawLine(
        Offset(b.right - 0.15 * s, l.trebleTop),
        Offset(b.right - 0.15 * s, l.bassBottom),
        _stroke(palette.ink, 0.45 * s)..strokeCap = StrokeCap.butt,
      );
    } else {
      canvas.drawLine(Offset(b.right, l.trebleTop), Offset(b.right, l.bassBottom), bar);
    }
    // Measure number (tap target lives in the header row).
    final number = b.measure?.number ?? '';
    if (number.isNotEmpty) {
      final sel = b.index == selectedMeasure;
      final tp = _text(
        number,
        _ts(
          1.25 * s,
          sel ? palette.selection : palette.ink.withValues(alpha: 0.7),
          weight: sel ? FontWeight.w700 : FontWeight.w500,
        ),
      );
      final pos = Offset(b.x + 0.5 * s, l.headerH * 0.55 - tp.height / 2);
      tp.paint(canvas, pos);
      if (showConfidence && b.uncertain) {
        _badge(canvas, Offset(pos.dx + tp.width + 1.0 * s, l.headerH * 0.55), _Badge.question, SlColors.warn);
      }
    }
    // Attributes: clef, key, time.
    var x = b.x + 0.4 * s;
    if (b.showClef) {
      _trebleClef(canvas, Offset(x + 1.4 * s, l.trebleTop + 3 * s));
      _bassClef(canvas, Offset(x + 0.6 * s, l.bassTop + 1 * s));
      x += l.clefWidth;
    }
    if (b.key != null) {
      if (b.cancelFifths != 0) {
        _keySignature(canvas, x, b.cancelFifths, natural: true);
        x += l.keyWidth(b.cancelFifths.abs());
      } else {
        _keySignature(canvas, x, b.key!.fifths);
        x += l.keyWidth(b.key!.fifths.abs());
      }
    }
    if (b.time != null) _timeSignature(canvas, x + 1.1 * s, b.time!);
  }

  void _keySignature(Canvas canvas, double x, int fifths, {bool natural = false}) {
    const sharps = [45, 42, 46, 43, 40, 44, 41], flats = [41, 44, 40, 43, 39, 42, 38];
    final l = layout;
    final positions = fifths > 0 ? sharps : flats;
    for (var k = 0; k < fifths.abs(); k++) {
      final cx = x + 0.6 * s + k * s;
      for (final staff in [1, 2]) {
        final d = staff == 1 ? positions[k] : positions[k] - 14;
        _accidental(canvas, Offset(cx, l.yFor(staff, d)), natural ? 0 : (fifths > 0 ? 1 : -1), palette.ink);
      }
    }
  }

  void _timeSignature(Canvas canvas, double cx, TimeSignature t) {
    final l = layout;
    final style = _ts(2.3 * s, palette.ink, weight: FontWeight.w800);
    for (final top in [l.trebleTop, l.bassTop]) {
      _drawText(canvas, '${t.beats}', Offset(cx, top + 1 * s), style);
      _drawText(canvas, '${t.beatType}', Offset(cx, top + 3 * s), style);
    }
  }

  void _stickyHeader(Canvas canvas, double off) {
    final l = layout;
    if (l.measures.isEmpty) return;
    final b = l.measures[l.measureIndexAtX(off + l.clefWidth)];
    final key = b.measure == null ? const KeySignature(0) : StaffLayout.displayKey(b.measure!.key, l.transpose);
    final w = l.clefWidth + l.keyWidth(key.fifths.abs()) + 0.6 * s;
    final rect = Rect.fromLTWH(off, 0, w, l.height);
    canvas.drawRect(rect, _fill(palette.background));
    _staffLines(canvas, off, off + w);
    canvas.drawLine(
      Offset(off + w, l.trebleTop - s),
      Offset(off + w, l.bassBottom + s),
      _stroke(palette.line.withValues(alpha: 0.25), 1),
    );
    _trebleClef(canvas, Offset(off + 1.8 * s, l.trebleTop + 3 * s));
    _bassClef(canvas, Offset(off + 1.0 * s, l.bassTop + 1 * s));
    _keySignature(canvas, off + l.clefWidth, key.fifths);
    if (l.showPedal) _laneLabel(canvas, off);
  }

  // ---- Notes ----

  void _note(Canvas canvas, NoteGlyph g) {
    final l = layout;
    final selected = g.id == selectedNoteId;
    final outcome = outcomes?[g.id];
    final uncertain = showConfidence && g.uncertain;
    final recognized = showConfidence && omr && !g.note.verified;
    final color = recognized ? palette.recognized : palette.ink;
    final c = Offset(g.x, g.y);
    final hw = l.headW;

    final ledger = _stroke(palette.ink.withValues(alpha: 0.8), math.max(1, 0.12 * s))..strokeCap = StrokeCap.butt;
    for (final y in g.ledgerYs) {
      canvas.drawLine(Offset(g.x - hw * 0.8, y), Offset(g.x + hw * 0.8, y), ledger);
    }
    if (selected) {
      canvas.drawCircle(c, 1.5 * s, _fill(palette.selection.withValues(alpha: 0.22)));
      canvas.drawCircle(c, 1.5 * s, _stroke(palette.selection, 2));
    }
    canvas.save();
    canvas.translate(g.x, g.y);
    canvas.rotate(-0.33);
    final oval = Rect.fromCenter(center: Offset.zero, width: hw, height: hw * 0.7);
    if (g.filled) {
      canvas.drawOval(oval, _fill(color));
    } else {
      canvas.drawOval(oval.deflate(0.09 * s), _stroke(color, (g.base >= 1920 ? 0.24 : 0.18) * s));
    }
    canvas.restore();
    if (uncertain) {
      final ring = Path()..addOval(Rect.fromCenter(center: c, width: hw + 0.8 * s, height: hw * 0.7 + 0.8 * s));
      canvas.drawPath(_dashed(ring, 0.35 * s, 0.25 * s), _stroke(SlColors.warn, math.max(1.5, 0.18 * s)));
    }
    if (l.noteNames) {
      final letter = Pitch.stepLetters[g.spelling.step];
      _drawText(canvas, letter, c, _ts(0.95 * s, g.filled ? palette.background : color, weight: FontWeight.w700));
    }
    if (g.showAccidental) _accidental(canvas, Offset(g.accidentalX, g.y), g.spelling.alter, color);
    for (var k = 0; k < g.dots; k++) {
      final dx = g.x + hw / 2 + 0.55 * s + k * 0.6 * s + (g.stemUp && g.offset ? 0 : 0);
      canvas.drawCircle(Offset(dx, g.onLine ? g.y - s / 2 : g.y), 0.2 * s, _fill(color));
    }
    // Hand letter only when it differs from what the staff implies (R on treble, L on bass).
    final implied = g.staff == 1 ? Hand.right : Hand.left;
    if (g.note.hand != Hand.unassigned && g.note.hand != implied) {
      final label = g.note.hand == Hand.right ? 'R' : 'L';
      _drawText(
        canvas,
        label,
        Offset(g.x, g.y + (g.stemUp ? 1.5 : -1.5) * s),
        _ts(
          0.95 * s,
          SlColors.hand(g.note.hand, palette.background.computeLuminance() < 0.3 ? Brightness.dark : Brightness.light),
          weight: FontWeight.w800,
        ),
      );
    }
    if (showFingers && g.note.finger != null) {
      final dy = g.staff == 1 ? -2.0 : 2.0;
      final y = g.staff == 1
          ? math.min(g.y + dy * s, l.trebleTop - 1.2 * s)
          : math.max(g.y + dy * s, l.bassBottom + 1.2 * s);
      _drawText(
        canvas,
        '${g.note.finger}',
        Offset(g.x, y),
        _ts(1.0 * s, palette.ink.withValues(alpha: 0.8), weight: FontWeight.w600),
      );
    }
    final badgeAt = Offset(g.x + hw * 0.6 + 0.6 * s, g.y - 1.3 * s);
    if (outcome != null && outcome != NoteOutcome.pending) {
      switch (outcome) {
        case NoteOutcome.correct || NoteOutcome.early || NoteOutcome.late:
          _badge(canvas, badgeAt, _Badge.check, SlColors.good);
        case NoteOutcome.wrongPitch || NoteOutcome.octaveMismatch || NoteOutcome.missed:
          _badge(canvas, badgeAt, _Badge.cross, SlColors.bad);
        default:
          _badge(canvas, badgeAt, _Badge.question, SlColors.unsure);
      }
    } else if (uncertain) {
      _badge(canvas, badgeAt, _Badge.question, SlColors.warn);
    } else if (showConfidence && omr && g.note.verified) {
      _check(canvas, Offset(g.x + hw * 0.5 + 0.35 * s, g.y - 0.9 * s), 0.35 * s, SlColors.good, 0.13 * s);
    }
  }

  void _stem(Canvas canvas, StemGlyph st) {
    final p = _stroke(palette.ink, math.max(1, 0.12 * s))..strokeCap = StrokeCap.butt;
    canvas.drawLine(Offset(st.x, st.y0), Offset(st.x, st.y1), p);
    final dir = st.up ? 1.0 : -1.0;
    for (var k = 0; k < st.flags; k++) {
      final y = st.y1 + dir * k * 0.85 * s;
      final path = Path()
        ..moveTo(st.x, y)
        ..cubicTo(
          st.x + 0.15 * s,
          y + dir * 1.0 * s,
          st.x + 1.4 * s,
          y + dir * 1.3 * s,
          st.x + 0.85 * s,
          y + dir * 2.6 * s,
        );
      canvas.drawPath(path, _stroke(palette.ink, 0.22 * s));
    }
  }

  void _tie(Canvas canvas, TieGlyph t) {
    final dir = t.above ? -1.0 : 1.0;
    final h = math.min(1.0 * s, 0.25 * (t.x1 - t.x0)) + 0.3 * s;
    final path = Path()
      ..moveTo(t.x0, t.y)
      ..cubicTo(t.x0 + (t.x1 - t.x0) * 0.25, t.y + dir * h, t.x1 - (t.x1 - t.x0) * 0.25, t.y + dir * h, t.x1, t.y)
      ..cubicTo(
        t.x1 - (t.x1 - t.x0) * 0.25,
        t.y + dir * (h - 0.22 * s),
        t.x0 + (t.x1 - t.x0) * 0.25,
        t.y + dir * (h - 0.22 * s),
        t.x0,
        t.y,
      )
      ..close();
    canvas.drawPath(path, _fill(palette.ink));
  }

  void _rest(Canvas canvas, RestGlyph r) {
    final y = r.staffTop + 2 * s + r.voiceShift;
    final x = r.x;
    final ink = _fill(palette.ink);
    switch (r.base) {
      case >= 1920:
        canvas.drawRect(Rect.fromLTWH(x - 0.6 * s, y - s, 1.2 * s, 0.5 * s), ink);
      case 960:
        canvas.drawRect(Rect.fromLTWH(x - 0.6 * s, y - 0.5 * s, 1.2 * s, 0.5 * s), ink);
      case 480:
        final path = Path()
          ..moveTo(x - 0.15 * s, y - 1.5 * s)
          ..lineTo(x + 0.45 * s, y - 0.7 * s)
          ..lineTo(x - 0.25 * s, y + 0.1 * s)
          ..lineTo(x + 0.35 * s, y + 0.8 * s)
          ..quadraticBezierTo(x - 0.5 * s, y + 0.6 * s, x - 0.05 * s, y + 1.4 * s);
        canvas.drawPath(path, _stroke(palette.ink, 0.28 * s)..strokeJoin = StrokeJoin.round);
      default:
        final n = math.max(1, StaffLayout.flagCount(r.base));
        final p = _stroke(palette.ink, 0.16 * s);
        canvas.drawLine(
          Offset(x + 0.5 * s, y - 0.9 * s),
          Offset(x - 0.2 * s - (n - 1) * 0.3 * s, y + 1.2 * s + (n - 1) * 0.6 * s),
          p,
        );
        for (var k = 0; k < n; k++) {
          final yy = y - 0.6 * s + k * s;
          final xx = x + 0.5 * s - k * 0.33 * s;
          canvas.drawCircle(Offset(xx - 0.85 * s, yy - 0.1 * s), 0.27 * s, ink);
          canvas.drawLine(Offset(xx - 0.8 * s, yy + 0.05 * s), Offset(xx, yy - 0.3 * s), p);
        }
    }
    for (var k = 0; k < r.dots; k++) {
      canvas.drawCircle(Offset(x + 1.0 * s + k * 0.6 * s, y - 0.5 * s), 0.2 * s, ink);
    }
  }

  // ---- Pedal lane ----

  void _laneLabel(Canvas canvas, double x) {
    final l = layout;
    final tp = _text('Pedal', _ts(0.95 * s, palette.ink.withValues(alpha: 0.6), weight: FontWeight.w600));
    tp.paint(canvas, Offset(x + 0.3 * s, l.pedalTop - 1.6 * s));
  }

  void _pedalLane(Canvas canvas, double left, double right) {
    final l = layout;
    if (left < l.leftMargin + l.clefWidth) _laneLabel(canvas, 0);
    final y = l.pedalMid + 0.7 * s;
    for (final sp in l.pedalSpans) {
      if (sp.x1 < left || sp.x0 > right) continue;
      final dashed = showConfidence && sp.uncertain;
      final p = _stroke(palette.ink.withValues(alpha: 0.8), math.max(1.2, 0.14 * s))..strokeCap = StrokeCap.butt;
      final path = Path()
        ..moveTo(sp.x0, y)
        ..lineTo(sp.x1, y);
      if (!sp.open) path.lineTo(sp.x1, y - 0.9 * s);
      canvas.drawPath(dashed ? _dashed(path, 0.6 * s, 0.4 * s) : path, p);
    }
    for (final g in l.pedals) {
      if (g.rect.right < left || g.rect.left > right) continue;
      final uncertain = showConfidence && g.uncertain;
      final color = uncertain ? SlColors.warn : palette.ink;
      if (g.id == selectedPedalId) {
        final r = RRect.fromRectAndRadius(g.rect.inflate(0.3 * s), Radius.circular(0.5 * s));
        canvas.drawRRect(r, _fill(palette.selection.withValues(alpha: 0.22)));
        canvas.drawRRect(r, _stroke(palette.selection, 2));
      }
      if (g.down) {
        final tp = _text('Ped.', _ts(1.35 * s, color, weight: FontWeight.w700, style: FontStyle.italic));
        tp.paint(canvas, Offset(g.x - 0.1 * s, l.pedalMid - tp.height / 2));
      } else {
        _pedalStar(canvas, Offset(g.x, l.pedalMid), 0.95 * s, color);
      }
      if (uncertain) {
        canvas.drawPath(
          _dashed(Path()..addRRect(RRect.fromRectAndRadius(g.rect, Radius.circular(0.4 * s))), 0.4 * s, 0.3 * s),
          _stroke(SlColors.warn, math.max(1.2, 0.13 * s)),
        );
        _badge(canvas, Offset(g.rect.right, g.rect.top + 0.2 * s), _Badge.question, SlColors.warn);
      }
    }
  }

  // ---- Glyph paths ----

  void _trebleClef(Canvas canvas, Offset o) {
    final u = s;
    Offset p(double x, double y) => o + Offset(x * u, y * u);
    final path = Path()
      ..moveTo(p(0.25, 0.6).dx, p(0.25, 0.6).dy)
      ..cubicTo(
        p(-0.6, 0.6).dx,
        p(-0.6, 0.6).dy,
        p(-0.65, -0.6).dx,
        p(-0.65, -0.6).dy,
        p(0.1, -0.7).dx,
        p(0.1, -0.7).dy,
      )
      ..cubicTo(p(1.05, -0.8).dx, p(1.05, -0.8).dy, p(1.25, 0.75).dx, p(1.25, 0.75).dy, p(0.3, 1.1).dx, p(0.3, 1.1).dy)
      ..cubicTo(
        p(-0.85, 1.45).dx,
        p(-0.85, 1.45).dy,
        p(-1.55, 0.3).dx,
        p(-1.55, 0.3).dy,
        p(-0.85, -0.75).dx,
        p(-0.85, -0.75).dy,
      )
      ..cubicTo(
        p(-0.35, -1.5).dx,
        p(-0.35, -1.5).dy,
        p(0.75, -2.3).dx,
        p(0.75, -2.3).dy,
        p(0.8, -3.4).dx,
        p(0.8, -3.4).dy,
      )
      ..cubicTo(
        p(0.85, -4.3).dx,
        p(0.85, -4.3).dy,
        p(0.25, -4.75).dx,
        p(0.25, -4.75).dy,
        p(-0.05, -4.0).dx,
        p(-0.05, -4.0).dy,
      )
      ..cubicTo(
        p(-0.4, -3.1).dx,
        p(-0.4, -3.1).dy,
        p(-0.05, -1.0).dx,
        p(-0.05, -1.0).dy,
        p(0.3, 1.7).dx,
        p(0.3, 1.7).dy,
      )
      ..cubicTo(p(0.42, 2.5).dx, p(0.42, 2.5).dy, p(-0.05, 2.9).dx, p(-0.05, 2.9).dy, p(-0.5, 2.6).dx, p(-0.5, 2.6).dy);
    canvas.drawPath(path, _stroke(palette.ink, 0.2 * u)..strokeJoin = StrokeJoin.round);
    canvas.drawCircle(p(-0.4, 2.35), 0.3 * u, _fill(palette.ink));
  }

  void _bassClef(Canvas canvas, Offset o) {
    final u = s;
    Offset p(double x, double y) => o + Offset(x * u, y * u);
    canvas.drawCircle(p(0.05, 0.05), 0.36 * u, _fill(palette.ink));
    final path = Path()
      ..moveTo(p(-0.25, 0.0).dx, p(-0.25, 0.0).dy)
      ..cubicTo(
        p(-0.1, -1.1).dx,
        p(-0.1, -1.1).dy,
        p(1.95, -1.25).dx,
        p(1.95, -1.25).dy,
        p(2.0, 0.2).dx,
        p(2.0, 0.2).dy,
      )
      ..cubicTo(p(2.05, 1.35).dx, p(2.05, 1.35).dy, p(1.0, 2.2).dx, p(1.0, 2.2).dy, p(-0.25, 2.8).dx, p(-0.25, 2.8).dy);
    canvas.drawPath(path, _stroke(palette.ink, 0.26 * u)..strokeJoin = StrokeJoin.round);
    canvas.drawCircle(p(2.65, -0.5), 0.18 * u, _fill(palette.ink));
    canvas.drawCircle(p(2.65, 0.5), 0.18 * u, _fill(palette.ink));
  }

  void _accidental(Canvas canvas, Offset c, int alter, Color color) {
    final u = s;
    Offset p(double x, double y) => c + Offset(x * u, y * u);
    final thin = _stroke(color, 0.11 * u)..strokeCap = StrokeCap.butt;
    final thick = _stroke(color, 0.24 * u)..strokeCap = StrokeCap.butt;
    switch (alter) {
      case 1:
        canvas.drawLine(p(-0.22, -1.25), p(-0.22, 1.35), thin);
        canvas.drawLine(p(0.22, -1.35), p(0.22, 1.25), thin);
        canvas.drawLine(p(-0.5, -0.3), p(0.5, -0.55), thick);
        canvas.drawLine(p(-0.5, 0.55), p(0.5, 0.3), thick);
      case 2:
        final x = _stroke(color, 0.2 * u);
        canvas.drawLine(p(-0.4, -0.4), p(0.4, 0.4), x);
        canvas.drawLine(p(-0.4, 0.4), p(0.4, -0.4), x);
      case -1 || -2:
        for (var k = 0; k < (alter == -2 ? 2 : 1); k++) {
          final dx = -k * 0.7;
          canvas.drawLine(p(dx - 0.3, -1.7), p(dx - 0.3, 0.5), thin);
          final bowl = Path()
            ..moveTo(p(dx - 0.3, 0.5).dx, p(dx - 0.3, 0.5).dy)
            ..cubicTo(
              p(dx + 0.65, 0.0).dx,
              p(dx + 0.65, 0.0).dy,
              p(dx + 0.55, -0.75).dx,
              p(dx + 0.55, -0.75).dy,
              p(dx - 0.3, -0.15).dx,
              p(dx - 0.3, -0.15).dy,
            );
          canvas.drawPath(bowl, _stroke(color, 0.17 * u));
        }
      default:
        canvas.drawLine(p(-0.28, -1.2), p(-0.28, 0.55), thin);
        canvas.drawLine(p(0.28, -0.55), p(0.28, 1.2), thin);
        canvas.drawLine(p(-0.28, -0.25), p(0.28, -0.42), thick);
        canvas.drawLine(p(-0.28, 0.42), p(0.28, 0.25), thick);
    }
  }

  void _pedalStar(Canvas canvas, Offset c, double r, Color color) {
    canvas.drawCircle(c, r * 0.32, _stroke(color, 0.13 * s));
    final p = _stroke(color, 0.17 * s);
    for (var k = 0; k < 8; k++) {
      final a = k * math.pi / 4;
      final d = Offset(math.cos(a), math.sin(a));
      canvas.drawLine(c + d * r * 0.5, c + d * r, p);
    }
  }

  void _check(Canvas canvas, Offset c, double r, Color color, double w) {
    final path = Path()
      ..moveTo(c.dx - r, c.dy)
      ..lineTo(c.dx - r * 0.25, c.dy + r * 0.7)
      ..lineTo(c.dx + r, c.dy - r * 0.75);
    canvas.drawPath(path, _stroke(color, w)..strokeJoin = StrokeJoin.round);
  }

  void _badge(Canvas canvas, Offset c, _Badge kind, Color color) {
    final r = 0.75 * s;
    canvas.drawCircle(c, r + 1, _fill(palette.background));
    canvas.drawCircle(c, r, _fill(color));
    final w = math.max(1.4, 0.18 * s);
    switch (kind) {
      case _Badge.check:
        _check(canvas, c, r * 0.5, Colors.white, w);
      case _Badge.cross:
        final p = _stroke(Colors.white, w);
        canvas.drawLine(c + Offset(-r * 0.4, -r * 0.4), c + Offset(r * 0.4, r * 0.4), p);
        canvas.drawLine(c + Offset(-r * 0.4, r * 0.4), c + Offset(r * 0.4, -r * 0.4), p);
      case _Badge.question:
        _drawText(canvas, '?', c, _ts(1.1 * s, Colors.white, weight: FontWeight.w800));
    }
  }

  static Path _dashed(Path src, double dash, double gap) {
    final out = Path();
    for (final m in src.computeMetrics()) {
      var d = 0.0;
      while (d < m.length) {
        out.addPath(m.extractPath(d, math.min(d + dash, m.length)), Offset.zero);
        d += dash + gap;
      }
    }
    return out;
  }

  // ---- Semantics ----

  @override
  SemanticsBuilderCallback get semanticsBuilder => (size) {
    final l = layout;
    final out = <CustomPainterSemantics>[];
    if (l.measures.isEmpty) return out;
    final (first, last) = visible;
    for (var i = first; i <= math.min(last, l.measures.length - 1); i++) {
      final b = l.measures[i];
      final m = b.measure;
      if (m == null) continue;
      final review = showConfidence && b.uncertain ? ', needs review' : (m.verified ? ', verified' : '');
      out.add(
        CustomPainterSemantics(
          key: ValueKey('m$i'),
          rect: l.headerRect(b),
          properties: SemanticsProperties(
            label: 'Measure ${m.number}, ${m.time.label}, ${m.key.label}$review',
            button: onMeasureTap != null,
            selected: i == selectedMeasure,
            textDirection: TextDirection.ltr,
            onTap: onMeasureTap == null ? null : () => onMeasureTap!(i),
          ),
        ),
      );
      for (final g in b.notes) {
        final o = outcomes?[g.id];
        final status = [
          if (showConfidence && g.uncertain) 'uncertain',
          if (showConfidence && omr && g.note.verified) 'verified',
          if (o != null && o != NoteOutcome.pending) o.name,
        ].join(', ');
        out.add(
          CustomPainterSemantics(
            key: ValueKey('n${g.id}'),
            rect: Rect.fromCenter(center: Offset(g.x, g.y), width: math.max(l.headW, 24), height: math.max(s, 24)),
            properties: SemanticsProperties(
              label: '${l.describe(g)}${status.isEmpty ? '' : ', $status'}',
              button: onNoteTap != null,
              selected: g.id == selectedNoteId,
              textDirection: TextDirection.ltr,
              onTap: onNoteTap == null ? null : () => onNoteTap!(g.id),
            ),
          ),
        );
      }
    }
    final x0 = l.measures[first].x, x1 = l.measures[math.min(last, l.measures.length - 1)].right;
    for (final g in l.pedals) {
      if (g.x < x0 || g.x > x1) continue;
      out.add(
        CustomPainterSemantics(
          key: ValueKey('p${g.id}'),
          rect: g.rect,
          properties: SemanticsProperties(
            label: 'Pedal ${g.down ? 'down' : 'up'}${showConfidence && g.uncertain ? ', unverified' : ''}',
            button: onPedalTap != null,
            selected: g.id == selectedPedalId,
            textDirection: TextDirection.ltr,
            onTap: onPedalTap == null ? null : () => onPedalTap!(g.id),
          ),
        ),
      );
    }
    return out;
  };

  @override
  bool shouldRebuildSemantics(_StaffPainter old) =>
      old.layout != layout ||
      old.visible != visible ||
      old.selectedNoteId != selectedNoteId ||
      old.selectedMeasure != selectedMeasure ||
      old.selectedPedalId != selectedPedalId ||
      old.outcomes != outcomes;

  @override
  bool shouldRepaint(_StaffPainter old) =>
      old.layout != layout ||
      old.palette != palette ||
      old.selectedNoteId != selectedNoteId ||
      old.selectedMeasure != selectedMeasure ||
      old.selectedPedalId != selectedPedalId ||
      old.highlightMeasure != highlightMeasure ||
      old.cursorTick != cursorTick ||
      old.outcomes != outcomes ||
      old.viewportWidth != viewportWidth ||
      old.showFingers != showFingers ||
      old.showConfidence != showConfidence;
}

enum _Badge { check, cross, question }
