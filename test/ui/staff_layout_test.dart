import 'package:flutter_test/flutter_test.dart';
import 'package:stavelight/core/model/pitch.dart';
import 'package:stavelight/core/model/score.dart';
import 'package:stavelight/ui/render/staff_view.dart';

Score _score({List<ScoreNote>? notes, List<PedalEvent>? pedals, KeySignature key = const KeySignature(0), int measures = 2}) => Score(
      title: 't',
      origin: ScoreOrigin.musicxml,
      measures: [
        for (var i = 0; i < measures; i++)
          Measure(index: i, startTick: i * 1920, lengthTicks: 1920, number: '${i + 1}', time: const TimeSignature(4, 4), key: key),
      ],
      notes: notes,
      pedals: pedals,
    );

ScoreNote _n(String id, int midi, int start, {int dur = 480, int staff = 1, int? acc}) =>
    ScoreNote(id: id, midi: midi, startTick: start, durationTicks: dur, staff: staff, accidental: acc);

void main() {
  test('note x order follows ticks across measures', () {
    final notes = [for (var i = 0; i < 8; i++) _n('n$i', 60 + i, i * 480)];
    final l = StaffLayout(_score(notes: notes));
    final xs = [for (var i = 0; i < 8; i++) l.byId['n$i']!.x];
    for (var i = 1; i < xs.length; i++) {
      expect(xs[i], greaterThan(xs[i - 1]));
    }
    expect(l.byId['n4']!.x, greaterThan(l.measures[0].right), reason: 'measure 2 note is right of the first barline');
    expect(l.xForTick(480), closeTo(l.byId['n1']!.x, 0.001));
    expect(l.xForTick(720), allOf(greaterThan(xs[1]), lessThan(xs[2])));
  });

  test('treble pitch to vertical position, with ledger lines', () {
    final l = StaffLayout(_score(notes: [
      _n('e4', 64, 0),
      _n('f5', 77, 480),
      _n('c4', 60, 960),
      _n('c6', 84, 1440),
    ]));
    final s = l.s;
    expect(l.byId['e4']!.y, closeTo(l.trebleTop + 4 * s, 1e-9));
    expect(l.byId['f5']!.y, closeTo(l.trebleTop, 1e-9));
    expect(l.byId['c4']!.y, closeTo(l.trebleTop + 5 * s, 1e-9));
    expect(l.byId['c4']!.ledgerYs, [l.trebleTop + 5 * s]);
    expect(l.byId['c6']!.ledgerYs.length, 2); // A5 and C6
    expect(l.byId['e4']!.ledgerYs, isEmpty);
  });

  test('bass pitch to vertical position, with ledger lines', () {
    final l = StaffLayout(_score(notes: [
      _n('g2', 43, 0, staff: 2),
      _n('a3', 57, 480, staff: 2),
      _n('c4', 60, 960, staff: 2),
      _n('e2', 40, 1440, staff: 2),
    ]));
    final s = l.s;
    expect(l.byId['g2']!.y, closeTo(l.bassTop + 4 * s, 1e-9));
    expect(l.byId['a3']!.y, closeTo(l.bassTop, 1e-9));
    expect(l.byId['c4']!.y, closeTo(l.bassTop - s, 1e-9));
    expect(l.byId['c4']!.ledgerYs, [l.bassTop - s]);
    expect(l.byId['e2']!.ledgerYs, [l.bassTop + 5 * s]);
    expect(StaffLayout.ledgerLines(2, 21), [23, 21]);
  });

  test('spelling follows the key signature', () {
    final eb = StaffLayout.spell(63, const KeySignature(-3));
    expect((eb.step, eb.alter, eb.inKey, eb.label), (2, -1, true, 'E♭4'));
    final ds = StaffLayout.spell(63, const KeySignature(0));
    expect((ds.step, ds.alter, ds.inKey), (1, 1, false));
    final fNat = StaffLayout.spell(65, const KeySignature(1));
    expect((fNat.step, fNat.alter, fNat.inKey), (3, 0, false));
    final db = StaffLayout.spell(61, const KeySignature(0), accidental: -1);
    expect(db.label, 'D♭4');
    final cb = StaffLayout.spell(59, const KeySignature(-7));
    expect((cb.label, cb.diatonic), ('C♭4', Pitch.diatonicIndex(0, 4)));
    expect(StaffLayout.spell(60, const KeySignature(7)).label, 'B♯3');

    // In E♭ major the E♭ sits on the bottom treble line without an accidental; D♯ in C major sits a step lower.
    final inEb = StaffLayout(_score(notes: [_n('a', 63, 0)], key: const KeySignature(-3)));
    expect(inEb.byId['a']!.y, closeTo(inEb.trebleTop + 4 * inEb.s, 1e-9));
    expect(inEb.byId['a']!.showAccidental, isFalse);
    final inC = StaffLayout(_score(notes: [_n('a', 63, 0)]));
    expect(inC.byId['a']!.y, closeTo(inC.trebleTop + 4.5 * inC.s, 1e-9));
    expect(inC.byId['a']!.showAccidental, isTrue);
  });

  test('durations, dots and chords sharing a stem', () {
    expect(StaffLayout.noteValue(720, 0), (480, 1));
    expect(StaffLayout.noteValue(720, 1), (480, 1));
    expect(StaffLayout.noteValue(240, 0), (240, 0));
    expect(StaffLayout.noteValue(3840, 0), (1920, 0));
    final l = StaffLayout(_score(notes: [_n('c', 72, 0), _n('e', 76, 0), ScoreNote(id: 'g', midi: 79, startTick: 0, durationTicks: 240, voice: 2), _n('w', 48, 0, dur: 1920, staff: 2)]));
    expect(l.measures[0].stems.length, 2, reason: 'voice-1 chord stem + voice-2 eighth stem; whole note has none');
  });

  test('hit testing returns the note, measure header or pedal under the finger', () {
    final l = StaffLayout(_score(
      notes: [_n('a', 72, 0), _n('b', 74, 480), _n('low', 48, 480, staff: 2)],
      pedals: [PedalEvent(id: 'pd', tick: 0, type: PedalType.down), PedalEvent(id: 'pu', tick: 1920, type: PedalType.up)],
    ));
    final b = l.byId['b']!;
    expect(l.hitTest(Offset(b.x, b.y))?.id, 'b');
    expect(l.hitTest(Offset(b.x + 4, b.y - 4))?.id, 'b');
    final low = l.byId['low']!;
    expect(l.hitTest(Offset(low.x, low.y))?.id, 'low');
    final header = l.hitTest(Offset(l.measures[1].x + 20, 10));
    expect((header?.kind, header?.measureIndex), (StaffHitKind.measure, 1));
    final pd = l.pedals.firstWhere((p) => p.id == 'pd');
    final hit = l.hitTest(pd.rect.center);
    expect((hit?.kind, hit?.id), (StaffHitKind.pedal, 'pd'));
    expect(l.pedalSpans.length, 1);
    expect(l.hitTest(const Offset(-5, 5)), isNull);
  });

  test('accidentals carry through the measure per staff', () {
    final l = StaffLayout(_score(notes: [
      _n('fs', 66, 0),
      _n('f', 65, 480),
      _n('f2', 65, 960),
      _n('bassF', 53, 480, staff: 2),
      _n('nextBar', 65, 1920),
    ]));
    expect(l.byId['fs']!.showAccidental, isTrue);
    expect((l.byId['f']!.showAccidental, l.byId['f']!.spelling.alter), (true, 0), reason: 'natural cancels the earlier sharp');
    expect(l.byId['f2']!.showAccidental, isFalse);
    expect(l.byId['bassF']!.showAccidental, isFalse, reason: 'other staff is unaffected');
    expect(l.byId['nextBar']!.showAccidental, isFalse, reason: 'barline resets');
  });

  test('vertical room grows for the full piano range', () {
    final base = StaffLayout(_score(notes: [_n('mid', 64, 0)]));
    final l = StaffLayout(_score(notes: [
      _n('c8', 108, 0),
      _n('a0', 21, 0, staff: 2),
      _n('highBass', 84, 480, staff: 2),
      _n('lowTreble', 43, 960),
    ]));
    final c8 = l.byId['c8']!, a0 = l.byId['a0']!, hb = l.byId['highBass']!, lt = l.byId['lowTreble']!;
    expect(c8.y, greaterThan(l.headerH + l.s));
    expect(a0.y, lessThan(l.pedalTop - l.s));
    expect(hb.y, greaterThan(lt.y + l.s), reason: 'staves never overlap');
    expect(hb.y, greaterThan(l.trebleBottom + l.s));
    expect(l.height, greaterThan(base.height));
    for (final id in ['c8', 'a0', 'highBass', 'lowTreble']) {
      final g = l.byId[id]!;
      expect(l.hitTest(Offset(g.x, g.y))?.id, id);
    }
  });

  test('transposed display shifts key and pitch', () {
    final l = StaffLayout(_score(notes: [_n('a', 60, 0)]), transpose: 2);
    expect(l.measures[0].key?.fifths, 2);
    expect(l.byId['a']!.spelling.label, 'D4');
  });

  test('large scores lay out quickly', () {
    final notes = [for (var i = 0; i < 4000; i++) _n('n$i', 48 + i % 30, i * 120, dur: 120, staff: i.isEven ? 1 : 2)];
    final sw = Stopwatch()..start();
    final l = StaffLayout(_score(notes: notes, measures: 250));
    expect(l.measures.length, 250);
    expect(sw.elapsedMilliseconds, lessThan(2000));
  });

  test('pedal change: release and press marks at the same tick do not overlap', () {
    final l = StaffLayout(_score(
      notes: [ScoreNote(id: 'n', midi: 60, startTick: 0, durationTicks: 1920)],
      pedals: [
        PedalEvent(id: 'd1', tick: 0, type: PedalType.down),
        PedalEvent(id: 'u1', tick: 960, type: PedalType.up),
        PedalEvent(id: 'd2', tick: 960, type: PedalType.down),
      ],
    ));
    final up = l.pedals.firstWhere((g) => g.event.id == 'u1');
    final down = l.pedals.firstWhere((g) => g.event.id == 'd2');
    expect(up.rect.right, lessThanOrEqualTo(down.rect.left));
    expect(l.hitTest(up.rect.center)?.id, 'u1');
    expect(l.hitTest(down.rect.center)?.id, 'd2');
  });
}
