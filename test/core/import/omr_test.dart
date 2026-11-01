import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:stavelight/core/import/import_types.dart';
import 'package:stavelight/core/import/omr/omr_engine.dart';
import 'package:stavelight/core/import/omr/preprocess.dart';
import 'package:stavelight/core/model/pitch.dart';
import 'package:stavelight/core/model/score.dart';

import 'omr_test_pages.dart';

int _m(String name) {
  const steps = {'C': 0, 'D': 1, 'E': 2, 'F': 3, 'G': 4, 'A': 5, 'B': 6};
  final alter = name.contains('#') ? 1 : (name.contains('b') && name.length == 3 ? -1 : 0);
  return Pitch.fromStep(steps[name[0]]!, alter, int.parse(name[name.length - 1]));
}

List<ScoreNote> _notesIn(Score s, int measure, int staff) =>
    s.notes.where((n) => n.measureIndex == measure && n.staff == staff).toList()
      ..sort((a, b) => a.startTick != b.startTick ? a.startTick.compareTo(b.startTick) : a.midi.compareTo(b.midi));

/// Treble-only page: sharp + F4, F4 (accidental carries), half G4 | whole rest.
img.Image _singleStaffPage() {
  final p = SynthPage(1000, 400);
  final d = ScoreDrawer(p);
  const top = 150.0;
  d.staff(top, 60, 902);
  d.header(top, 60);
  for (final x in [60.0, 560.0, 900.0]) {
    d.barline(x, top, top + 80);
  }
  // sharp drawn just left of the F4 head at x = 280
  final cy = d.y(top, 1);
  const ax = 245.0;
  p.rect(ax + 4, cy - 26, ax + 7, cy + 30);
  p.rect(ax + 13, cy - 30, ax + 16, cy + 26);
  for (final off in [-9.0, 9.0]) {
    for (var x = ax; x < ax + 20; x++) {
      final yy = cy + off - (x - ax) * 0.3;
      p.rect(x, yy - 3, x + 1, yy + 4);
    }
  }
  d.note(top, 1, 280);
  d.note(top, 1, 360);
  d.note(top, 2, 450, hollow: true);
  p.rect(710, top + 20, 734, top + 30); // whole rest hanging from the 4th line
  return p.toImage();
}

img.Image _noisy(img.Image src, {int seed = 7}) {
  final rnd = math.Random(seed);
  final blurred = img.gaussianBlur(src.clone(), radius: 2);
  final out = img.Image(width: src.width, height: src.height, numChannels: 1);
  for (var y = 0; y < src.height; y++) {
    for (var x = 0; x < src.width; x++) {
      final light = 0.78 + 0.22 * x / src.width; // uneven lighting
      var v = blurred.getPixel(x, y).r * light + rnd.nextInt(41) - 20;
      if (rnd.nextDouble() < 0.002) v = rnd.nextBool() ? 0 : 255;
      final c = v.round().clamp(0, 255);
      out.setPixelRgb(x, y, c, c, c);
    }
  }
  return out;
}

void main() {
  group('grand staff page', () {
    late OmrResult res;
    setUpAll(() => res = runOmr([grandStaffPage().toImage()], const OmrSettings(), title: 'Synthetic'));

    test('finds both staves with the right spacing', () {
      final r = res.pages.single;
      expect(r.ok, isTrue);
      expect(r.stavesFound, 2);
      expect(r.staffSpacingPx, closeTo(20, 1));
      expect(r.notesFound, 17);
      expect(r.meanConfidence, inExclusiveRange(0, 1));
    });

    test('barlines split the system into three measures with page boxes', () {
      final ms = res.score.measures;
      expect(ms.length, 3);
      for (var i = 0; i < 3; i++) {
        expect(ms[i].startTick, i * 4 * kPpq);
        expect(ms[i].page, 0);
        expect(ms[i].x0! < ms[i].x1!, isTrue);
        expect(ms[i].y0! < ms[i].y1!, isTrue);
      }
      expect(ms[1].x0, closeTo(600 / 1600, 0.01));
      expect(ms[2].x0, closeTo(1050 / 1600, 0.01));
    });

    test('treble pitches, chord grouping and durations (measure 1)', () {
      final n = _notesIn(res.score, 0, 1);
      expect(n.map((e) => e.midi).toList(), [_m('G4'), _m('G4'), _m('D5'), _m('A4')]);
      expect(n.map((e) => e.startTick).toList(), [0, kPpq, kPpq, 2 * kPpq]); // G4+D5 chord shares an onset
      expect(n.map((e) => e.durationTicks).toList(), [kPpq, kPpq, kPpq, 2 * kPpq]);
      expect(n.every((e) => e.hand == Hand.right), isTrue);
    });

    test('bass whole note, stems down, rest, ledger middle C', () {
      final m1 = _notesIn(res.score, 0, 2);
      expect(m1.single.midi, _m('C3'));
      expect(m1.single.durationTicks, 4 * kPpq);
      expect(m1.single.hand, Hand.left);
      final m2 = _notesIn(res.score, 1, 2);
      expect(m2.map((e) => e.midi).toList(), [_m('F3'), _m('D3')]); // F3 on the 4th line
      final rest = res.score.rests.single;
      expect(rest.staff, 2);
      expect(rest.durationTicks, 2 * kPpq);
      expect(rest.startTick, 4 * kPpq + 2 * kPpq);
      expect(rest.confidence, lessThanOrEqualTo(0.5));
      final m3t = _notesIn(res.score, 2, 1);
      expect(m3t.first.midi, 60); // middle C on a ledger line
      final m3b = _notesIn(res.score, 2, 2);
      expect(m3b.map((e) => e.midi).toList(), [_m('G2'), _m('B2'), _m('D3')]);
      expect(m3b.last.durationTicks, 2 * kPpq);
    });

    test('beamed eighths, dotted quarter and flagged eighth (measure 2)', () {
      final n = _notesIn(res.score, 1, 1);
      expect(n.map((e) => e.midi).toList(), [_m('E4'), _m('G4'), _m('A4'), _m('C5'), _m('F4')]);
      expect(n.map((e) => e.durationTicks).toList(), [kPpq ~/ 2, kPpq ~/ 2, kPpq * 3 ~/ 2, kPpq ~/ 2, kPpq]);
      expect(n[2].dots, 1);
      const m = 4 * kPpq;
      expect(n.map((e) => e.startTick - m).toList(), [0, 240, 480, 1200, 1440]);
      expect(n[0].flags.any((f) => f.contains('Beamed')), isTrue);
    });

    test('incomplete measure is flagged', () {
      final ms = res.score.measures;
      expect(ms[0].flags, isEmpty);
      expect(ms[1].flags.where((f) => f.contains("Rhythm doesn't add up")), isEmpty);
      expect(ms[2].flags.any((f) => f.contains("Rhythm doesn't add up (2 of 4 beats")), isTrue);
      expect(ms[2].confidence, lessThan(ms[0].confidence));
    });

    test('nothing is verified and every confidence is below 1', () {
      final s = res.score;
      expect(s.origin, ScoreOrigin.omr);
      expect(s.review, ReviewState.recognized);
      expect(s.notes.every((n) => !n.verified && n.confidence < 1 && n.confidence > 0), isTrue);
      expect(s.measures.every((m) => !m.verified && m.confidence < 1), isTrue);
      expect(s.rests.every((r) => r.confidence <= 0.5), isTrue);
      expect(s.pedals.every((p) => !p.verified && p.confidence <= 0.35), isTrue);
      expect(s.pedalDataPresent, s.pedals.isNotEmpty);
      expect(s.tempos.single.bpm, 90);
      expect(s.issues.any((i) => i.message.startsWith('Clef, key and time signature were set by you')), isTrue);
      expect(s.issues.any((i) => i.message.toLowerCase().contains('pedal')), isTrue);
    });
  });

  test('key signature from settings applies (G major: F -> F#)', () {
    final res = runOmr([grandStaffPage().toImage()], const OmrSettings(key: KeySignature(1)), title: 'G');
    final f = _notesIn(res.score, 1, 1).last;
    expect(f.midi, _m('F#4'));
    expect(f.accidental, isNull);
    expect(res.score.measures.every((m) => m.key == const KeySignature(1)), isTrue);
  });

  test('measures continue across pages; a failing page does not stop others', () {
    final good = grandStaffPage().toImage();
    final blank = SynthPage(800, 1000).toImage();
    final res = runOmr([good, blank, good], const OmrSettings(), title: 'Two');
    expect(res.pages.map((p) => p.ok).toList(), [true, false, true]);
    expect(res.anyUsable, isTrue);
    expect(res.score.measures.length, 6);
    expect(res.score.measures.map((m) => m.page).toList(), [0, 0, 0, 2, 2, 2]);
    expect(res.score.measures[3].startTick, 3 * 4 * kPpq);
    expect(res.score.notes.where((n) => n.measureIndex == 3).length, 5);
    expect(res.score.issues.any((i) => i.message.startsWith('Page 2:') && i.severity == 'error'), isTrue);
  });

  test('single staff: unassigned hand, sharp detected and carried, whole rest', () {
    final res = runOmr(
      [_singleStaffPage()],
      const OmrSettings(grandStaff: false, singleClef: ClefKind.treble),
      title: 'Single',
    );
    expect(res.pages.single.stavesFound, 1);
    final n = _notesIn(res.score, 0, 1);
    expect(n.length, 3);
    expect(n.every((e) => e.hand == Hand.unassigned && e.staff == 1), isTrue);
    expect(n[0].flags, contains('Accidental detected — check type'));
    expect(n[0].confidence, lessThan(n[2].confidence));
    expect(n[0].midi, _m('F#4'));
    expect(n[0].accidental, 1);
    expect(n[1].midi, _m('F#4')); // accidental lasts until the barline
    expect(n[2].midi, _m('G4'));
    expect(n[2].durationTicks, 2 * kPpq);
    final rest = res.score.rests.single;
    expect(rest.durationTicks, 4 * kPpq);
    expect(rest.startTick, 4 * kPpq);
    expect(res.score.measures.length, 2);
    expect(res.score.measures[0].flags, isEmpty);
  });

  test('pedal marks become low-confidence candidates only', () {
    final page = grandStaffPage().toImage();
    img.drawString(page, 'Ped.', font: img.arial48, x: 250, y: 520, color: img.ColorRgb8(0, 0, 0));
    for (var i = 0; i < 6; i++) {
      final a = i * math.pi / 3;
      img.drawLine(
        page,
        x1: 560,
        y1: 545,
        x2: (560 + 14 * math.cos(a)).round(),
        y2: (545 + 14 * math.sin(a)).round(),
        color: img.ColorRgb8(0, 0, 0),
        thickness: 3,
      );
    }
    final res = runOmr([page], const OmrSettings(), title: 'Pedal');
    final s = res.score;
    expect(s.notes.length, 17); // the text below the staff did not become notes
    expect(s.pedals.any((p) => p.type == PedalType.down), isTrue);
    expect(s.pedals.every((p) => p.confidence <= 0.35 && !p.verified && p.source == 'omr'), isTrue);
    expect(s.pedals.first.tick, lessThan(4 * kPpq));
    expect(s.pedalDataPresent, isTrue);
    expect(s.issues.any((i) => i.message.contains('pedal marks')), isTrue);
  });

  test('blank page fails with a clear reason', () {
    final res = runOmr([SynthPage(1200, 1600).toImage()], const OmrSettings(), title: 'Blank');
    final r = res.pages.single;
    expect(r.ok, isFalse);
    expect(r.failureReason, startsWith('No staff lines detected'));
    expect(r.hints, isNotEmpty);
    expect(res.anyUsable, isFalse);
    expect(res.score.notes, isEmpty);
  });

  test('tiny low-resolution page fails with a resolution hint', () {
    final p = SynthPage(320, 90);
    final d = ScoreDrawer(p, s: 5, t: 1);
    d.staff(30, 10, 310);
    d.staff(60, 10, 310);
    final r = runOmr([p.toImage()], const OmrSettings(), title: 'Tiny').pages.single;
    expect(r.ok, isFalse);
    expect(r.failureReason, contains('Resolution too low'));
  });

  test('strongly tilted page fails with a tilt hint', () {
    final r = runOmr([rotateWhite(grandStaffPage().toImage(), 25)], const OmrSettings(), title: 'Tilt').pages.single;
    expect(r.ok, isFalse);
    expect(r.failureReason, contains('tilted'));
  });

  test('slightly tilted page is straightened automatically', () {
    final res = runOmr([rotateWhite(grandStaffPage().toImage(), 2)], const OmrSettings(), title: 'Skew');
    final r = res.pages.single;
    expect(r.ok, isTrue);
    expect(r.stavesFound, 2);
    expect(r.hints.any((h) => h.contains('tilted')), isTrue);
    expect(res.score.measures.length, 3);
    expect(r.notesFound, greaterThanOrEqualTo(15));
    expect(_notesIn(res.score, 0, 1).first.midi, _m('G4'));
  });

  test('blurred, noisy, unevenly lit page still finds staves and most notes', () {
    final res = runOmr([_noisy(grandStaffPage().toImage())], const OmrSettings(), title: 'Noisy');
    final r = res.pages.single;
    expect(r.ok, isTrue);
    expect(r.stavesFound, 2);
    expect(r.staffSpacingPx, closeTo(20, 1.5));
    expect(res.score.measures.length, 3);
    expect(r.notesFound, greaterThanOrEqualTo(15));
  });

  test('preprocess: rotate, crop, perspective, enhance, binarize', () {
    final src = grandStaffPage().toImage();
    final rot = rotateQuarter(src, 1);
    expect((rot.width, rot.height), (src.height, src.width));
    expect(rotateQuarter(rotateQuarter(src, 1), -1).getPixel(250, 260).r, src.getPixel(250, 260).r);
    final crop = cropNormalized(src, 0.25, 0.25, 0.75, 0.75);
    expect((crop.width, crop.height), (800, 400));
    final same = perspectiveCorrect(src, const [(0, 0), (1, 0), (1, 1), (0, 1)]);
    expect((same.width, same.height), (src.width - 1, src.height - 1));
    final warped = perspectiveCorrect(src, const [(0.05, 0.1), (0.95, 0.05), (1, 0.95), (0, 1)]);
    expect(warped.width, greaterThan(100));
    final enh = enhanceForOmr(img.Image(width: 10, height: 10)..clear(img.ColorRgb8(200, 100, 50)), contrast: 1.5);
    expect(enh.numChannels, 1);
    final bin = binarize(src);
    expect(bin.get(250, 260), 1); // notehead
    expect(bin.get(50, 50), 0); // paper
    expect(limitSize(img.Image(width: 5200, height: 300)).width, 2600);
    expect(identical(limitSize(src), src), isTrue);
    // Rotated-back page is still recognized.
    final back = runOmr([rotateQuarter(rot, -1)], const OmrSettings(), title: 'R');
    expect(back.score.measures.length, 3);
  });

  test('very large scan is downscaled but spacing is reported in original pixels', () {
    final big = img.copyResize(grandStaffPage().toImage(), width: 4800, interpolation: img.Interpolation.average);
    final r = runOmr([big], const OmrSettings(), title: 'Huge').pages.single;
    expect(r.ok, isTrue);
    expect(r.staffSpacingPx, closeTo(60, 3));
    expect(r.notesFound, 17);
  });

  test('empty page list throws', () {
    expect(() => runOmr([], const OmrSettings(), title: 'x'), throwsA(isA<ImportException>()));
  });

  test(
    'large clean and noisy pages run in reasonable time',
    () {
      final p = SynthPage(2500, 3500);
      final d = ScoreDrawer(p, s: 24, t: 3);
      for (var sys = 0; sys < 6; sys++) {
        final up = 300.0 + sys * 520, lo = up + 240;
        d.staff(up, 150, 2350);
        d.staff(lo, 150, 2350);
        d.header(up, 150);
        d.header(lo, 150);
        for (final x in [150.0, 850.0, 1600.0, 2348.0]) {
          d.barline(x, up, lo + 96);
        }
        for (var i = 0; i < 12; i++) {
          final x = const [250.0, 850.0, 1600.0][i ~/ 4] + 90 + (i % 4) * 150;
          d.note(up, 2 + i % 5, x);
          d.note(lo, 1 + i % 4, x, stem: Stem.down);
        }
      }
      final sw = Stopwatch()..start();
      final res = runOmr([p.toImage()], const OmrSettings(), title: 'Big');
      final ms = sw.elapsedMilliseconds;
      expect(res.pages.single.stavesFound, 12);
      expect(res.score.measures.length, 18);
      expect(ms, lessThan(60000), reason: 'took $ms ms (debug JIT)');
      // Photo-like input (blur, speckle, uneven light) creates many small components.
      final sw2 = Stopwatch()..start();
      final noisy = runOmr([_noisy(p.toImage())], const OmrSettings(), title: 'Big noisy');
      final ms2 = sw2.elapsedMilliseconds;
      expect(noisy.pages.single.stavesFound, 12);
      expect(ms2, lessThan(60000), reason: 'took $ms2 ms (debug JIT)');
      },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
