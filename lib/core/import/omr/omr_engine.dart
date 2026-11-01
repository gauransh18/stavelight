import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../../model/pitch.dart';
import '../../model/score.dart';
import '../../util/ids.dart';
import '../import_types.dart';
import 'preprocess.dart';

/// Classical-CV draft recognizer (projection staff finding, line removal, blob noteheads).
/// It is a heuristic: every symbol carries a confidence estimate, nothing is verified, and
/// pages it cannot read get a specific failure reason. See docs/ARCHITECTURE.md "OMR — honest limits".
OmrResult runOmr(List<img.Image> pages, OmrSettings settings, {required String title}) {
  if (pages.isEmpty) throw ImportException('No pages to recognize.', 'runOmr called with an empty page list');
  final reports = <OmrPageReport>[];
  final drafts = <_MeasureDraft>[];
  final issues = <ScoreIssue>[
    ScoreIssue(
      'Clef, key and time signature were set by you before recognition — confirm they match the page.',
      severity: 'info',
    ),
    ScoreIssue(
      'This is a recognized draft. Ties, slurs, tuplets, grace notes, multiple voices and dynamics are not read — '
      'check every flagged measure.',
      severity: 'info',
    ),
  ];
  for (var i = 0; i < pages.length; i++) {
    try {
      final r = _PageRecognizer(pages[i], i, settings).run();
      reports.add(r.report);
      drafts.addAll(r.measures);
      issues.addAll(r.issues);
      if (!r.report.ok) issues.add(ScoreIssue('Page ${i + 1}: ${r.report.failureReason}', severity: 'error'));
    } catch (e) {
      const reason = 'Recognition failed on this page.';
      reports.add(
        OmrPageReport(
          pageIndex: i,
          ok: false,
          failureReason: reason,
          hints: const [
            'Try cropping to the music, straightening the page and increasing contrast, then run recognition again.',
            'You can also enter this page by hand in the editor.',
          ],
        ),
      );
      issues.add(ScoreIssue('Page ${i + 1}: $reason', severity: 'error'));
    }
  }

  final score = Score(
    title: title,
    origin: ScoreOrigin.omr,
    review: ReviewState.recognized,
    tempos: [TempoEvent(0, settings.bpm)],
    issues: issues,
  );
  _assemble(score, drafts, settings);
  score.issues.add(
    ScoreIssue(
      score.pedals.isEmpty
          ? 'No pedal markings were recognized — they are hard to read from scans; add them in review if the piece '
                'uses pedal.'
          : 'Possible pedal marks were found with low confidence — check each one in review.',
      severity: 'info',
    ),
  );
  score.pedalDataPresent = score.pedals.isNotEmpty;
  if (score.notes.isNotEmpty) {
    final midis = score.notes.map((n) => n.midi);
    score.tracks.add(
      TrackInfo(
        index: 0,
        name: 'Recognized piano',
        noteCount: score.notes.length,
        lowest: midis.reduce(math.min),
        highest: midis.reduce(math.max),
      ),
    );
  }
  score.normalize();
  return OmrResult(score, reports);
}

// ---------------------------------------------------------------------------------------------
// Internal structures

class _Comp {
  int x0, y0, x1, y1, area = 0;
  double sx = 0, sy = 0;
  bool border = false;
  _Comp(this.x0, this.y0, this.x1, this.y1);
  int get w => x1 - x0 + 1;
  int get h => y1 - y0 + 1;
  double get cx => sx / area;
  double get cy => sy / area;
  double get fill => area / (w * h);
}

class _Staff {
  final List<double> ys; // 5 line centres, top to bottom
  final List<(int, int)> bands; // ink rows of each line
  int x0 = 0, x1 = 0;
  double t = 1;
  ClefKind clef = ClefKind.treble;
  int staffNo = 1;
  Hand hand = Hand.unassigned;
  int headerEnd = 0;
  _Staff(this.ys, this.bands);
  double get s => (ys[4] - ys[0]) / 4;
  double get top => ys[0];
  double get bottom => ys[4];
}

class _Head {
  int x0, y0, x1, y1;
  double cx, cy;
  final bool hollow;
  double shape;
  bool cluster;
  _Staff? staff;
  int stemX = -1, stemDir = 0, beams = 0;
  double stemLen = 0;
  bool beamed = false, dot = false, accDetected = false;
  int? accGuess;
  int diatonic = 0, midi = 60, durTicks = kPpq;
  double snapErr = 0, durConf = 0.5;
  final List<String> flags = [];
  _Head(
    this.x0,
    this.y0,
    this.x1,
    this.y1,
    this.cx,
    this.cy, {
    required this.hollow,
    required this.shape,
    this.cluster = false,
  });
}

class _Rest {
  final double cx;
  final int durTicks; // -1 = whole-measure rest
  final double conf;
  final _Staff staff;
  _Rest(this.cx, this.durTicks, this.conf, this.staff);
}

class _MeasureDraft {
  final int page;
  final double x0, x1, y0, y1;
  final List<_Staff> staves;
  final Map<_Staff, List<_Head>> heads = {};
  final Map<_Staff, List<_Rest>> rests = {};
  final List<String> flags = [];
  final List<(double, PedalType, double)> pedals = []; // fraction across measure, type, confidence
  _MeasureDraft(this.page, this.x0, this.x1, this.y0, this.y1, this.staves);
}

class _PageResult {
  final OmrPageReport report;
  final List<_MeasureDraft> measures;
  final List<ScoreIssue> issues;
  _PageResult(this.report, [this.measures = const [], this.issues = const []]);
}

// ---------------------------------------------------------------------------------------------
// Page recognition

class _PageRecognizer {
  final img.Image page;
  final int index;
  final OmrSettings settings;
  late BinaryImage b; // binarized, deskewed
  late BinaryImage r; // staff/ledger lines removed
  late int w, h;
  double skewDeg = 0;
  final hints = <String>[];
  final issues = <ScoreIssue>[];

  /// Longer side used for processing; large pages are downscaled for speed.
  final int maxSide;
  double scale = 1; // original px per processing px

  _PageRecognizer(this.page, this.index, this.settings, {this.maxSide = 2600});

  _PageResult fail(String reason, List<String> extra, {int staves = 0, double s = 0}) => _PageResult(
    OmrPageReport(
      pageIndex: index,
      ok: false,
      failureReason: reason,
      hints: [
        ...extra,
        ...hints.where((x) => !x.contains('straightened')),
        'You can enter this page by hand in the editor instead.',
      ],
      stavesFound: staves,
      staffSpacingPx: s,
    ),
  );

  _PageResult run() {
    final im = limitSize(page, maxSide: maxSide);
    scale = page.width / im.width;
    b = binarize(im);
    w = b.width;
    h = b.height;
    if (w < 16 || h < 16) {
      return fail('Resolution too low — rescan at higher resolution or move the camera closer', const []);
    }
    final ink = b.inkCount / (w * h);
    if (ink > 0.45) {
      return fail('Page is mostly dark — check lighting and contrast.', const [
        'Use Enhance, or retake the photo in even light without shadows.',
      ]);
    }

    skewDeg = _estimateSkew();
    if (skewDeg.abs() >= 0.15) {
      b = _rotate(b, skewDeg);
      if (skewDeg.abs() >= 0.4) {
        hints.add('Page was tilted about ${skewDeg.abs().toStringAsFixed(1)}° and was straightened automatically.');
      }
    }

    final rl = _runLengthStats();
    final tRl = rl.$1, sRl = rl.$1 + rl.$2;
    final pattern = rl.$3;
    final bands = _lineBands(tRl);
    var staves = _groupStaves(bands, sRl.toDouble());
    if (staves.isEmpty && bands.length >= 5) {
      final gaps = [for (var i = 1; i < bands.length; i++) bands[i].$1 - bands[i - 1].$1]..sort();
      staves = _groupStaves(bands, gaps[gaps.length ~/ 2]);
    }
    for (final st in staves) {
      _staffExtent(st);
    }
    staves.removeWhere((st) => st.x1 - st.x0 < 10 * st.s);

    if (staves.isEmpty) {
      final lowRes = sRl > 0 && sRl < 7;
      if (pattern >= 1.0 && lowRes) {
        return fail('Resolution too low — rescan at higher resolution or move the camera closer', [
          'Staff spacing looks like about $sRl px; 12 px or more works best.',
        ]);
      }
      if (pattern >= 1.0) {
        return fail('Page looks tilted — use rotate/perspective correction', const [
          'Line patterns were found but they are not horizontal or straight (tilt, curl or perspective).',
          'Flatten the page and use rotate/perspective correction, then run recognition again.',
        ]);
      }
      return fail('No staff lines detected. Make sure the page is upright, in focus, and fills the frame.', const [
        'Rotate the page so the music reads left to right.',
        'Crop away margins and other pages.',
      ]);
    }

    final sList = [for (final st in staves) st.s]..sort();
    final sMed = sList[sList.length ~/ 2];
    if (sMed < 10 && scale > 1.05) {
      // Downscaling made the staves too small; retry closer to the original resolution.
      final longer = math.max(page.width, page.height);
      return _PageRecognizer(page, index, settings, maxSide: math.min(longer, (maxSide * 12 / sMed).ceil())).run();
    }
    if (sMed < 7) {
      return fail(
        'Resolution too low — rescan at higher resolution or move the camera closer',
        ['Staff spacing is about ${(sMed * scale).toStringAsFixed(1)} px; 12 px or more works best.'],
        staves: staves.length,
        s: sMed * scale,
      );
    }
    final strongUnused = bands.where((bd) => bd.$4 >= 0.6 && !staves.any((st) => st.ys.contains(bd.$1))).length;
    var pageConf = 1.0;
    if (strongUnused >= 5) {
      hints.add(
        'Some staff lines could not be grouped — the page may be tilted or warped; consider perspective correction.',
      );
      pageConf *= 0.85;
    }
    final tList = [for (final st in staves) st.t]..sort();
    if (tList[tList.length ~/ 2] > 0.3 * sMed) {
      hints.add('Lines look thick or blurry — retake in focus or rescan at higher resolution.');
      pageConf *= 0.85;
    }
    if (skewDeg.abs() >= 0.4) pageConf *= 0.95;

    // Systems and clefs.
    final systems = <List<_Staff>>[];
    if (settings.grandStaff) {
      for (var i = 0; i + 1 < staves.length; i += 2) {
        staves[i]
          ..clef = settings.upperClef
          ..staffNo = 1
          ..hand = Hand.right;
        staves[i + 1]
          ..clef = settings.lowerClef
          ..staffNo = 2
          ..hand = Hand.left;
        systems.add([staves[i], staves[i + 1]]);
      }
      if (staves.length.isOdd) {
        final last = staves.last
          ..clef = settings.upperClef
          ..staffNo = 1
          ..hand = Hand.unassigned;
        systems.add([last]);
        issues.add(
          ScoreIssue(
            'Page ${index + 1}: found an odd number of staves (${staves.length}); the last staff was read on its own '
            'with the upper clef — check its clef and hand.',
          ),
        );
      }
    } else {
      for (final st in staves) {
        st
          ..clef = settings.singleClef
          ..staffNo = 1
          ..hand = Hand.unassigned;
        systems.add([st]);
      }
    }

    // Line removal, morphology, components.
    r = b.copy();
    for (final st in staves) {
      _removeLines(st);
    }
    final k = math.max(2, (0.55 * sMed).round());
    final opened = _open(r, k);
    final filledComps = _label(opened.bits, w, h, 1, true);
    final inkComps = _label(r.bits, w, h, 1, true);
    final holes = _label(r.bits, w, h, 0, false).where((c) => !c.border && c.area >= 4).toList();
    // Before line removal, heads in spaces keep intact holes even when blur makes line removal eat their rims.
    final holesB = _label(b.bits, w, h, 0, false).where((c) => !c.border && c.area >= 4 && c.h >= 0.35 * sMed).toList();

    var heads = <_Head>[];
    _findFilled(filledComps, opened, sMed, heads);
    _findHollow(holes, sMed, heads, r);
    _findHollow(holesB, sMed, heads, b);
    for (final hd in heads) {
      hd.staff = _nearestStaff(staves, hd.cx, hd.cy);
    }
    heads.removeWhere((hd) => hd.staff == null);
    heads.removeWhere(_looksLikeAccidental);
    heads = _dedupe(heads, sMed);
    for (final hd in heads) {
      _stem(hd);
    }
    for (final st in staves) {
      _header(st, inkComps, heads);
    }
    heads.removeWhere((hd) => hd.cx < hd.staff!.headerEnd);
    for (final hd in heads) {
      _pitch(hd);
    }
    heads.removeWhere((hd) => !_ledgerOk(hd));
    for (final hd in heads) {
      _beams(hd);
      _dotAndAccidental(hd, inkComps);
      _duration(hd, pageConf);
    }
    final rests = _rests(inkComps, staves, heads);

    // Measures per system.
    final out = <_MeasureDraft>[];
    for (final sys in systems) {
      out.addAll(_measures(sys, heads, rests, inkComps));
    }
    final noteConfs = [
      for (final m in out)
        for (final l in m.heads.values)
          for (final hd in l) _noteConf(hd),
    ];
    final mean = noteConfs.isEmpty ? 0.0 : noteConfs.reduce((a, b) => a + b) / noteConfs.length;
    if (noteConfs.isEmpty) hints.add('Staves were found but no noteheads were recognized — check contrast and crop.');
    return _PageResult(
      OmrPageReport(
        pageIndex: index,
        ok: true,
        hints: hints,
        stavesFound: staves.length,
        staffSpacingPx: sMed * scale,
        notesFound: noteConfs.length,
        meanConfidence: mean,
      ),
      out,
      issues,
    );
  }

  // --- skew -----------------------------------------------------------------------------------

  double _estimateSkew() {
    final xs = <int>[], ys = <int>[];
    final total = b.inkCount;
    final step = math.max(1, total ~/ 300000);
    var c = 0;
    for (var y = 0; y < h; y++) {
      final base = y * w;
      for (var x = 0; x < w; x += 2) {
        if (b.bits[base + x] == 1 && (c++ % step == 0)) {
          xs.add(x);
          ys.add(y);
        }
      }
    }
    if (xs.length < 50) return 0;
    final cx = w / 2;
    final pad = (w * math.tan(9 * math.pi / 180)).ceil() + 2;
    final hist = Int32List(h + 2 * pad);
    double score(double deg) {
      final tn = math.tan(deg * math.pi / 180);
      hist.fillRange(0, hist.length, 0);
      for (var i = 0; i < xs.length; i++) {
        final idx = (ys[i] - (xs[i] - cx) * tn).round() + pad;
        if (idx >= 0 && idx < hist.length) hist[idx]++;
      }
      var s = 0.0;
      for (final v in hist) {
        s += v * v;
      }
      return s;
    }

    final s0 = score(0);
    var best = 0.0, bestS = s0;
    for (var d = -8.0; d <= 8.0; d += 0.5) {
      final s = score(d);
      if (s > bestS) {
        bestS = s;
        best = d;
      }
    }
    final coarse = best;
    for (var d = coarse - 0.45; d <= coarse + 0.45; d += 0.05) {
      final s = score(d);
      if (s > bestS) {
        bestS = s;
        best = d;
      }
    }
    // At the edge of the search range the estimate is unreliable; leave the page alone.
    return bestS > s0 * 1.02 && best.abs() < 8.2 ? best : 0;
  }

  BinaryImage _rotate(BinaryImage src, double deg) {
    final a = deg * math.pi / 180, ca = math.cos(a), sa = math.sin(a);
    final out = BinaryImage(w, h);
    final cx = w / 2, cy = h / 2;
    for (var y = 0; y < h; y++) {
      final dy = y - cy;
      for (var x = 0; x < w; x++) {
        final dx = x - cx;
        final xs = (cx + dx * ca - dy * sa).round(), ys = (cy + dx * sa + dy * ca).round();
        if (xs >= 0 && ys >= 0 && xs < w && ys < h && src.bits[ys * w + xs] == 1) out.bits[y * w + x] = 1;
      }
    }
    return out;
  }

  /// Map a point from the deskewed frame back to the original page.
  (double, double) _unrotate(double x, double y) {
    if (skewDeg.abs() < 0.15) return (x, y);
    final a = skewDeg * math.pi / 180;
    final dx = x - w / 2, dy = y - h / 2;
    return (w / 2 + dx * math.cos(a) - dy * math.sin(a), h / 2 + dx * math.sin(a) + dy * math.cos(a));
  }

  // --- staff finding --------------------------------------------------------------------------

  /// (most common black run, most common white gap, staff-like pattern score per sampled column).
  (int, int, double) _runLengthStats() {
    final black = Int32List(64), white = Int32List(160);
    final cols = <List<int>>[];
    for (var x = 0; x < w; x += 3) {
      final runs = <int>[]; // alternating, starting with first black run
      var y = 0;
      while (y < h && b.bits[y * w + x] == 0) {
        y++;
      }
      while (y < h) {
        var n = 0;
        while (y < h && b.bits[y * w + x] == 1) {
          n++;
          y++;
        }
        runs.add(n);
        if (n < 64) black[n]++;
        var m = 0;
        while (y < h && b.bits[y * w + x] == 0) {
          m++;
          y++;
        }
        if (y < h) {
          runs.add(m);
          if (m < 160) white[m]++;
        }
      }
      cols.add(runs);
    }
    var t = 1, g = 2;
    for (var i = 1; i < 64; i++) {
      if (black[i] > black[t]) t = i;
    }
    for (var i = 2; i < 160; i++) {
      if (white[i] > white[g]) g = i;
    }
    if (black[t] == 0) return (0, 0, 0);
    final tt = math.max(1, t ~/ 3), gt = math.max(2, g ~/ 5);
    var triples = 0;
    for (final runs in cols) {
      for (var i = 0; i + 2 < runs.length; i += 2) {
        if ((runs[i] - t).abs() <= tt && (runs[i + 1] - g).abs() <= gt && (runs[i + 2] - t).abs() <= tt) triples++;
      }
    }
    return (t, g, cols.isEmpty ? 0 : triples / cols.length);
  }

  /// Horizontal projection bands: (centre y, top row, bottom row, relative strength).
  List<(double, int, int, double)> _lineBands(int tRl) {
    final rows = Int32List(h);
    var maxC = 0;
    for (var y = 0; y < h; y++) {
      var c = 0;
      final base = y * w;
      for (var x = 0; x < w; x++) {
        c += b.bits[base + x];
      }
      rows[y] = c;
      if (c > maxC) maxC = c;
    }
    final out = <(double, int, int, double)>[];
    if (maxC < math.max(8, w * 0.05)) return out;
    final thr = maxC * 0.35;
    var y = 0;
    while (y < h) {
      if (rows[y] < thr) {
        y++;
        continue;
      }
      final y0 = y;
      var peak = 0, sw = 0.0, s = 0.0;
      while (y < h && rows[y] >= thr) {
        peak = math.max(peak, rows[y]);
        sw += rows[y].toDouble();
        s += rows[y] * y.toDouble();
        y++;
      }
      out.add((s / sw, y0, y - 1, peak / maxC));
    }
    return out;
  }

  List<_Staff> _groupStaves(List<(double, int, int, double)> bands, double sEst) {
    final out = <_Staff>[];
    if (sEst < 3 || bands.length < 5) return out;
    var i = 0;
    while (i < bands.length) {
      final picked = [i];
      var gapRef = sEst;
      var cur = i;
      for (var j = 0; j < 4; j++) {
        final want = bands[cur].$1 + gapRef;
        var bestM = -1;
        var bestD = double.infinity;
        for (var m = cur + 1; m < bands.length; m++) {
          final gap = bands[m].$1 - bands[cur].$1;
          if (gap > gapRef * 1.35) break;
          if (gap < gapRef * 0.7) continue;
          final d = (bands[m].$1 - want).abs();
          if (d < bestD) {
            bestD = d;
            bestM = m;
          }
        }
        if (bestM < 0) break;
        if (j == 0) gapRef = bands[bestM].$1 - bands[cur].$1;
        picked.add(bestM);
        cur = bestM;
      }
      if (picked.length == 5) {
        final gaps = [for (var j = 1; j < 5; j++) bands[picked[j]].$1 - bands[picked[j - 1]].$1];
        final mx = gaps.reduce(math.max), mn = gaps.reduce(math.min);
        if (mn >= 3 && mx / mn <= 1.4) {
          final st = _Staff(
            [for (final p in picked) bands[p].$1],
            [for (final p in picked) (bands[p].$2, bands[p].$3)],
          );
          st.t = picked.map((p) => (bands[p].$3 - bands[p].$2 + 1).toDouble()).reduce((a, b) => a + b) / 5;
          out.add(st);
          i = picked.last + 1;
          continue;
        }
      }
      i++;
    }
    return out;
  }

  void _staffExtent(_Staff st) {
    final ok = Uint8List(w);
    for (var x = 0; x < w; x++) {
      var n = 0;
      for (final bd in st.bands) {
        for (var y = bd.$1 - 1; y <= bd.$2 + 1; y++) {
          if (y >= 0 && y < h && b.bits[y * w + x] == 1) {
            n++;
            break;
          }
        }
      }
      ok[x] = n >= 4 ? 1 : 0;
    }
    final maxGap = (2 * st.s).round();
    var bestA = 0, bestB = -1, a = -1, last = -1;
    for (var x = 0; x < w; x++) {
      if (ok[x] == 0) continue;
      if (a < 0 || x - last > maxGap) a = x;
      last = x;
      if (last - a > bestB - bestA) {
        bestA = a;
        bestB = last;
      }
    }
    st.x0 = bestA;
    st.x1 = math.max(bestA, bestB);
  }

  _Staff? _nearestStaff(List<_Staff> staves, double x, double y) {
    _Staff? best;
    var bestD = double.infinity;
    for (final st in staves) {
      if (x < st.x0 - st.s || x > st.x1 + st.s) continue;
      final d = y < st.top ? st.top - y : (y > st.bottom ? y - st.bottom : 0.0);
      if (d > 6.5 * st.s) continue;
      if (d < bestD) {
        bestD = d;
        best = st;
      }
    }
    return best;
  }

  // --- line removal -----------------------------------------------------------------------------

  /// Clear thin horizontal runs along a line. Only runs lying inside the line band (±1 px) are cleared,
  /// so symbols touching the line keep their pixels.
  void _clearLine(double yc, double t, int xa, int xb, {bool track = true}) {
    final half = t / 2 + 1;
    final maxRun = (t + 2).ceil();
    var yExp = yc;
    for (var x = math.max(0, xa); x <= math.min(w - 1, xb); x++) {
      final lo = (yExp - half - 1).floor(), hi = (yExp + half + 1).ceil();
      var y = math.max(0, lo);
      while (y <= hi && y < h) {
        if (r.bits[y * w + x] == 0) {
          y++;
          continue;
        }
        var y0 = y;
        while (y0 > 0 && r.bits[(y0 - 1) * w + x] == 1) {
          y0--;
        }
        var y1 = y;
        while (y1 < h - 1 && r.bits[(y1 + 1) * w + x] == 1) {
          y1++;
        }
        if (y1 - y0 + 1 <= maxRun && y0 >= lo && y1 <= hi) {
          for (var yy = y0; yy <= y1; yy++) {
            r.bits[yy * w + x] = 0;
          }
          if (track) yExp = 0.9 * yExp + 0.1 * ((y0 + y1) / 2);
        }
        y = y1 + 1;
      }
      if ((yExp - yc).abs() > t + 2) yExp = yc;
    }
  }

  void _removeLines(_Staff st) {
    final s = st.s;
    final pad = (1.5 * s).round();
    for (final y in st.ys) {
      _clearLine(y, st.t, st.x0 - pad, st.x1 + pad);
    }
    for (var k = 1; k <= 6; k++) {
      _clearLine(st.top - k * s, st.t, st.x0 - pad, st.x1 + pad, track: false);
      _clearLine(st.bottom + k * s, st.t, st.x0 - pad, st.x1 + pad, track: false);
    }
  }

  // --- morphology & labelling ---------------------------------------------------------------------

  BinaryImage _open(BinaryImage src, int k) {
    var a = _box(src.bits, k, true, true);
    a = _box(a, k, false, true);
    a = _box(a, k, true, false);
    a = _box(a, k, false, false);
    return BinaryImage(w, h, a);
  }

  /// Separable square erosion/dilation of size [k] along one axis.
  Uint8List _box(Uint8List src, int k, bool horizontal, bool erode) {
    final out = Uint8List(w * h);
    final k1 = k ~/ 2, k2 = k - 1 - k1;
    final len = horizontal ? w : h, lines = horizontal ? h : w;
    final pre = Int32List(len + 1);
    for (var l = 0; l < lines; l++) {
      final base = horizontal ? l * w : l;
      final stride = horizontal ? 1 : w;
      for (var i = 0; i < len; i++) {
        pre[i + 1] = pre[i] + src[base + i * stride];
      }
      if (pre[len] == 0) continue;
      for (var i = 0; i < len; i++) {
        if (erode) {
          final lo = i - k1, hi = i + k2;
          if (lo >= 0 && hi < len && pre[hi + 1] - pre[lo] == k) out[base + i * stride] = 1;
        } else {
          final lo = math.max(0, i - k2), hi = math.min(len - 1, i + k1);
          if (pre[hi + 1] - pre[lo] > 0) out[base + i * stride] = 1;
        }
      }
    }
    return out;
  }

  /// Connected components of pixels equal to [target] (8- or 4-connected), with border contact.
  List<_Comp> _label(Uint8List bits, int w, int h, int target, bool eight) {
    final labels = Int32List(w * h);
    final parent = <int>[0];
    int find(int a) {
      while (parent[a] != a) {
        parent[a] = parent[parent[a]];
        a = parent[a];
      }
      return a;
    }

    void union(int a, int b) {
      final ra = find(a), rb = find(b);
      if (ra != rb) parent[math.max(ra, rb)] = math.min(ra, rb);
    }

    for (var y = 0; y < h; y++) {
      final base = y * w;
      for (var x = 0; x < w; x++) {
        final i = base + x;
        if (bits[i] != target) continue;
        var lbl = 0;
        void take(int j) {
          final l = labels[j];
          if (l == 0) return;
          if (lbl == 0) {
            lbl = l;
          } else if (l != lbl) {
            union(lbl, l);
          }
        }

        if (x > 0) take(i - 1);
        if (y > 0) {
          take(i - w);
          if (eight) {
            if (x > 0) take(i - w - 1);
            if (x < w - 1) take(i - w + 1);
          }
        }
        if (lbl == 0) {
          lbl = parent.length;
          parent.add(lbl);
        }
        labels[i] = lbl;
      }
    }
    final remap = Int32List(parent.length);
    final comps = <_Comp>[];
    for (var l = 1; l < parent.length; l++) {
      final root = find(l);
      if (root == l) {
        remap[l] = comps.length;
        comps.add(_Comp(w, h, -1, -1));
      }
    }
    for (var l = 1; l < parent.length; l++) {
      remap[l] = remap[find(l)];
    }
    for (var y = 0; y < h; y++) {
      final base = y * w;
      for (var x = 0; x < w; x++) {
        final l = labels[base + x];
        if (l == 0) continue;
        final c = comps[remap[l]];
        if (x < c.x0) c.x0 = x;
        if (x > c.x1) c.x1 = x;
        if (y < c.y0) c.y0 = y;
        if (y > c.y1) c.y1 = y;
        c.area++;
        c.sx += x;
        c.sy += y;
        if (x == 0 || y == 0 || x == w - 1 || y == h - 1) c.border = true;
      }
    }
    return comps;
  }

  // --- noteheads --------------------------------------------------------------------------------

  void _findFilled(List<_Comp> comps, BinaryImage opened, double s, List<_Head> out) {
    for (final c in comps) {
      final cw = c.w / s, ch = c.h / s;
      if (c.area < 0.3 * s * s || cw < 0.75 || ch < 0.62 || cw > 3.2 || ch > 4.6) continue;
      if (ch <= 1.4 && cw / ch > 1.85) continue; // rest or beam fragment, too flat for a head
      if (cw <= 2.0 && ch <= 1.4) {
        if (c.fill < 0.55) continue;
        final shape =
            (1 -
                    1.1 * (cw / 1.3 - 1).abs() -
                    1.1 * (ch / 1.0 - 1).abs() -
                    2 * math.max(0.0, (c.fill - 0.78).abs() - 0.08))
                .clamp(0.05, 1.0);
        out.add(_Head(c.x0, c.y0, c.x1, c.y1, c.cx, c.cy, hollow: false, shape: shape));
        continue;
      }
      if (c.fill < 0.4) continue;
      // Cluster of touching heads (chord seconds/thirds): split into columns, then by height.
      final parts = <(int, int)>[];
      final nx = cw > 2.0 ? 2 : 1;
      for (var p = 0; p < nx; p++) {
        parts.add((c.x0 + (c.w * p) ~/ nx, c.x0 + (c.w * (p + 1)) ~/ nx - 1));
      }
      for (final (xa, xb) in parts) {
        var ya = -1, yb = -1;
        for (var y = c.y0; y <= c.y1; y++) {
          var any = false;
          for (var x = xa; x <= xb && !any; x++) {
            if (opened.bits[y * w + x] == 1) any = true;
          }
          if (any) {
            if (ya < 0) ya = y;
            yb = y;
          }
        }
        if (ya < 0) continue;
        final ph = (yb - ya + 1) / s;
        if (ph < 0.6) continue;
        final n = math.max(1, ((ph - 0.95) / 1.0).round() + 1);
        final headH = 0.95 * s;
        for (var i = 0; i < n; i++) {
          final cy = n == 1 ? (ya + yb) / 2 : ya + headH / 2 + i * ((yb - ya + 1) - headH) / (n - 1);
          out.add(
            _Head(
              xa,
              (cy - headH / 2).round(),
              xb,
              (cy + headH / 2).round(),
              (xa + xb) / 2,
              cy,
              hollow: false,
              shape: 0.5,
              cluster: n > 1 || nx > 1,
            ),
          );
        }
      }
    }
  }

  /// Ink run length from (x, y) going [dir] (-1 up, +1 down), tolerating 1-px gaps.
  int _run(int x, int y, int dir, int maxLen) {
    if (x < 0 || x >= w) return 0;
    var n = 0, gap = 0, yy = y;
    while (yy >= 0 && yy < h && n < maxLen) {
      if (r.bits[yy * w + x] == 1) {
        n += 1 + gap;
        gap = 0;
      } else if (++gap > 1) {
        break;
      }
      yy += dir;
    }
    return n;
  }

  /// Longest vertical run over columns [xa, xb], returning (length, column).
  (int, int) _stroke(int xa, int xb, int y, int dir, int maxLen) {
    var best = 0, bx = xa;
    for (var x = xa; x <= xb; x++) {
      final n = _run(x, y, dir, maxLen);
      if (n > best) {
        best = n;
        bx = x;
      }
    }
    return (best, bx);
  }

  void _findHollow(List<_Comp> holes, double s, List<_Head> out, BinaryImage src) {
    for (final c in holes) {
      final hw = c.w / s, hh = c.h / s;
      if (hw < 0.35 || hw > 1.25 || hh < 0.2 || hh > 1.0 || hw < 0.6 * hh) continue;
      final cy = c.cy.round(), cx = c.cx.round();
      int edge(int x, int y, int dx, int dy) {
        // pixels of ink after leaving the hole
        var xx = x, yy = y, n = 0;
        while (xx >= 0 && yy >= 0 && xx < w && yy < h && src.bits[yy * w + xx] == 0 && n < 4 * s) {
          xx += dx;
          yy += dy;
          n++;
        }
        var m = 0;
        while (xx >= 0 && yy >= 0 && xx < w && yy < h && src.bits[yy * w + xx] == 1 && m < 2 * s) {
          xx += dx;
          yy += dy;
          m++;
        }
        return m;
      }

      final left = edge(cx, cy, -1, 0), right = edge(cx, cy, 1, 0);
      final up = edge(cx, cy, 0, -1), down = edge(cx, cy, 0, 1);
      if (left == 0 || right == 0 || up == 0 || down == 0) continue;
      final side = math.min(left, right), cap = math.max(up, down);
      if (math.max(left, right) > 0.6 * s || cap > 0.6 * s) continue; // ring must be thin all round
      if (side < 0.5 * cap) continue; // stems around a beam gap, not a head ring
      final ox0 = c.x0 - left, ox1 = c.x1 + right, oy0 = c.y0 - up, oy1 = c.y1 + down;
      final ow = (ox1 - ox0 + 1) / s, oh = (oy1 - oy0 + 1) / s;
      if (ow < 0.9 || ow > 2.4 || oh < 0.65 || oh > 1.45) continue;
      final ew = ow > 1.55 ? 1.75 : 1.35; // whole notes are wider
      final shape = (1 - 0.9 * (ow / ew - 1).abs() - 1.1 * (oh / 1.05 - 1).abs()).clamp(0.05, 1.0);
      out.add(_Head(ox0, oy0, ox1, oy1, (ox0 + ox1) / 2, (oy0 + oy1) / 2, hollow: true, shape: shape));
    }
  }

  List<_Head> _dedupe(List<_Head> heads, double s) {
    heads.sort((a, b) => (a.hollow == b.hollow ? 0 : (a.hollow ? -1 : 1)));
    final out = <_Head>[];
    for (final hd in heads) {
      if (out.any((o) => (o.cx - hd.cx).abs() < 0.6 * s && (o.cy - hd.cy).abs() < 0.4 * s)) continue;
      if (!hd.hollow && out.any((o) => o.hollow && (o.cx - hd.cx).abs() < 0.8 * s && o.y0 < hd.y1 && o.y1 > hd.y0)) {
        continue;
      }
      out.add(hd);
    }
    return out;
  }

  void _stem(_Head hd) {
    final s = hd.staff!.s;
    final m = (6 * s).round(), q = math.max(1, (0.3 * s).round()), q2 = math.max(2, (0.45 * s).round());
    final cy = hd.cy.round();
    final ur = _stroke(hd.x1 - q, hd.x1 + q2, cy, -1, m);
    final dl = _stroke(hd.x0 - q2, hd.x0 + q, cy, 1, m);
    final need = 2.0 * s;
    if (ur.$1 >= need && ur.$1 >= dl.$1) {
      hd
        ..stemDir = 1
        ..stemLen = ur.$1.toDouble()
        ..stemX = ur.$2;
    } else if (dl.$1 >= need) {
      hd
        ..stemDir = -1
        ..stemLen = dl.$1.toDouble()
        ..stemX = dl.$2;
    }
  }

  /// Rings with strokes on the "wrong" sides are flats, sharps or naturals, not heads.
  bool _looksLikeAccidental(_Head hd) {
    final s = hd.staff!.s;
    final m = (4 * s).round(), q = math.max(1, (0.25 * s).round());
    final cy = hd.cy.round();
    final ul = _stroke(hd.x0 - q, hd.x0 + q, cy, -1, m).$1 / s;
    final dl = _stroke(hd.x0 - q, hd.x0 + q, cy, 1, m).$1 / s;
    final ur = _stroke(hd.x1 - q, hd.x1 + q, cy, -1, m).$1 / s;
    final dr = _stroke(hd.x1 - q, hd.x1 + q, cy, 1, m).$1 / s;
    if (ul >= 1.0 && dl >= 1.0 && ur >= 1.0 && dr >= 1.0) return true; // sharp
    if (ul >= 1.5 && dl < 0.7 && ur < 0.7 && dr < 0.7) return true; // flat
    if (ul >= 1.0 && dr >= 1.0 && dl < 0.7 && ur < 0.7) return true; // natural
    return false;
  }

  /// Skip clef / key / time signature: walk components from the staff start while gaps stay small.
  void _header(_Staff st, List<_Comp> comps, List<_Head> heads) {
    final s = st.s;
    final band =
        comps
            .where(
              (c) =>
                  c.y1 >= st.top - s &&
                  c.y0 <= st.bottom + s &&
                  c.x0 >= st.x0 - 2 * s &&
                  c.x0 < st.x0 + 14 * s &&
                  c.w < 5 * s,
            )
            .toList()
          ..sort((a, b) => a.x0.compareTo(b.x0));
    final maxEnd = st.x0 + (4.5 + 1.2 * settings.key.fifths.abs() + 3.5) * s;
    var end = st.x0;
    var started = false;
    for (final c in band) {
      if (c.area < 0.05 * s * s) continue;
      if (c.w <= 0.4 * s && c.h >= 3.5 * s && !started) {
        end = math.max(end, c.x1);
        continue;
      }
      final hasHead = heads.any(
        (hd) => hd.staff == st && hd.stemDir != 0 && hd.cx >= c.x0 && hd.cx <= c.x1 && hd.cy >= c.y0 && hd.cy <= c.y1,
      );
      if (hasHead && started) break;
      if (!started) {
        if (c.x0 > st.x0 + 3 * s) break;
        started = true;
        end = math.max(end, c.x1);
        continue;
      }
      if (c.x0 > end + 0.9 * s) break;
      end = math.max(end, c.x1);
    }
    st.headerEnd = math.min(end, maxEnd.round());
  }

  void _beams(_Head hd) {
    if (hd.stemDir == 0) return;
    final s = hd.staff!.s;
    final tip = hd.cy - hd.stemDir * hd.stemLen;
    final reach = math.min(2.2 * s, hd.stemLen - 0.9 * s);
    if (reach < 0.5 * s) return;
    final ya = hd.stemDir == 1 ? tip - 0.25 * s : tip - reach;
    final yb = hd.stemDir == 1 ? tip + reach : tip + 0.25 * s;
    int count(int x) {
      if (x < 0 || x >= w) return 0;
      var n = 0, run = 0;
      for (var y = math.max(0, ya.floor()); y <= math.min(h - 1, yb.ceil()) + 1; y++) {
        final on = y <= math.min(h - 1, yb.ceil()) && r.bits[y * w + x] == 1;
        if (on) {
          run++;
        } else {
          if (run >= 0.25 * s && run <= 1.6 * s) n++;
          run = 0;
        }
      }
      return n;
    }

    final off = (0.6 * s).round();
    final right = count(hd.stemX + off), left = count(hd.stemX - off);
    final nb = math.min(3, math.max(left, right));
    if (nb == 0) return;
    hd.beams = nb;
    hd.beamed = left > 0 || count(hd.stemX + (1.6 * s).round()) > 0;
  }

  void _dotAndAccidental(_Head hd, List<_Comp> comps) {
    final s = hd.staff!.s;
    final dotX0 = hd.stemDir == 1 ? math.max(hd.x1, hd.stemX) : hd.x1;
    for (final c in comps) {
      // augmentation dot: small round blob just right of the head, near its height
      if (c.w <= 0.65 * s && c.h <= 0.65 * s && c.w >= 0.2 * s && c.h >= 0.2 * s && c.fill >= 0.5) {
        if (c.x0 > dotX0 + 0.1 * s && c.x0 < hd.x1 + 1.3 * s && (c.cy - hd.cy).abs() <= 0.7 * s) hd.dot = true;
        continue;
      }
      // accidental: tall narrow component ending just left of the head
      if (c.h >= 1.5 * s &&
          c.h <= 3.6 * s &&
          c.w >= 0.35 * s &&
          c.w <= 1.4 * s &&
          c.x1 < hd.x0 + 0.1 * s &&
          c.x1 > hd.x0 - 1.6 * s &&
          c.y0 < hd.cy &&
          c.y1 > hd.cy) {
        hd.accDetected = true;
        hd.accGuess = _accidentalType(c, s);
      }
    }
  }

  /// Rough sharp/flat/natural guess from vertical strokes. Returns null when unclear.
  int? _accidentalType(_Comp c, double s) {
    final cov = <int>[];
    for (var x = c.x0; x <= c.x1; x++) {
      var n = 0;
      for (var y = c.y0; y <= c.y1; y++) {
        n += r.bits[y * w + x];
      }
      cov.add(n);
    }
    final strokes = <(int, int)>[]; // (column index, coverage)
    for (var i = 0; i < cov.length; i++) {
      if (cov[i] >= 0.55 * c.h && (strokes.isEmpty || i - strokes.last.$1 > math.max(2, 0.2 * s))) {
        strokes.add((i, cov[i]));
      } else if (strokes.isNotEmpty && i - strokes.last.$1 <= math.max(2, 0.2 * s) && cov[i] > strokes.last.$2) {
        strokes[strokes.length - 1] = (strokes.last.$1, cov[i]);
      }
    }
    if (strokes.length == 1) {
      // flat: one full stroke, ink mass in the lower half
      var top = 0, bottom = 0;
      final mid = (c.y0 + c.y1) ~/ 2;
      for (var y = c.y0; y <= c.y1; y++) {
        for (var x = c.x0; x <= c.x1; x++) {
          if (r.bits[y * w + x] == 1) y < mid ? top++ : bottom++;
        }
      }
      return bottom > top * 1.3 ? -1 : null;
    }
    if (strokes.length == 2) {
      final both = strokes.every((st) => st.$2 >= 0.8 * c.h);
      if (both && c.w >= 0.7 * s) return 1;
      return 0;
    }
    return null;
  }

  /// Heads two or more steps outside the staff need a ledger line (nearest the staff) sticking out beside them.
  /// Rejects text, dynamics and pedal marks that look like heads.
  bool _ledgerOk(_Head hd) {
    final st = hd.staff!;
    final s = st.s;
    final k = ((st.bottom - hd.cy) / (s / 2)).round();
    if (k > -2 && k < 10) return true;
    final yl = k <= -2 ? st.bottom + s : st.top - s;
    final ya = (yl - st.t / 2 - 2).floor(), yb = (yl + st.t / 2 + 2).ceil();
    int cols(int xa, int xb) {
      var n = 0;
      for (var x = math.max(0, xa); x <= math.min(w - 1, xb); x++) {
        for (var y = math.max(0, ya); y <= math.min(h - 1, yb); y++) {
          if (b.bits[y * w + x] == 1) {
            n++;
            break;
          }
        }
      }
      return n;
    }

    final reach = math.max(2, (0.3 * s).round());
    return cols(hd.x1 + 1, hd.x1 + reach) >= 2 || cols(hd.x0 - reach, hd.x0 - 1) >= 2;
  }

  void _pitch(_Head hd) {
    final st = hd.staff!;
    final pos = (st.bottom - hd.cy) / (st.s / 2);
    final k = pos.round();
    hd.snapErr = (pos - k).abs();
    final base = st.clef == ClefKind.treble ? Pitch.diatonicIndex(2, 4) : Pitch.diatonicIndex(4, 2);
    hd.diatonic = base + k;
    if (k < -6 || k > 14) hd.flags.add('Many ledger lines — check octave');
  }

  void _duration(_Head hd, double pageConf) {
    var d = kPpq;
    if (hd.hollow) {
      if (hd.stemDir != 0) {
        d = 2 * kPpq;
        hd.durConf = 0.9;
        if (hd.beams > 0) hd.flags.add('Hollow head with beam — check duration');
      } else {
        d = 4 * kPpq;
        hd.durConf = (hd.x1 - hd.x0 + 1) >= 1.4 * hd.staff!.s ? 0.8 : 0.55;
      }
    } else if (hd.stemDir == 0) {
      hd.durConf = 0.35;
      hd.flags.add('Duration guessed (no stem found)');
    } else if (hd.beams > 0) {
      d = kPpq >> hd.beams;
      hd.durConf = hd.beamed ? 0.6 : 0.7;
      hd.flags.add(hd.beamed ? 'Beamed — duration estimated from beam count' : 'Flag detected — check duration');
    } else {
      hd.durConf = 0.9;
    }
    if (hd.dot) d = d * 3 ~/ 2;
    hd.durTicks = d;
    if (hd.shape < 0.6) hd.flags.add('Low notehead confidence');
    if (hd.cluster) hd.flags.add('Clustered noteheads split — check chord');
    if (hd.snapErr > 0.3) hd.flags.add('Pitch position unclear (between line and space)');
    if (hd.accDetected) hd.flags.add('Accidental detected — check type');
    hd.shape *= pageConf;
  }

  // --- rests ------------------------------------------------------------------------------------

  List<_Rest> _rests(List<_Comp> comps, List<_Staff> staves, List<_Head> heads) {
    final out = <_Rest>[];
    for (final c in comps) {
      final st = _nearestStaff(staves, c.cx, c.cy);
      if (st == null || c.cx < st.headerEnd) continue;
      final s = st.s;
      if (c.cy < st.top - 0.5 * s || c.cy > st.bottom + 0.5 * s) continue;
      final nearHead = heads.any(
        (hd) =>
            hd.x0 - 0.3 * s <= c.x1 && hd.x1 + 0.3 * s >= c.x0 && hd.y0 - 0.3 * s <= c.y1 && hd.y1 + 0.3 * s >= c.y0,
      );
      if (nearHead) continue;
      final cw = c.w / s, ch = c.h / s;
      if (cw >= 0.8 && cw <= 1.7 && ch >= 0.3 && ch <= 0.8 && c.fill >= 0.75) {
        if ((c.y0 - st.ys[1]).abs() <= 0.35 * s) {
          out.add(_Rest(c.cx, -1, 0.45, st));
        } else if ((c.y1 - st.ys[2]).abs() <= 0.35 * s) {
          out.add(_Rest(c.cx, 2 * kPpq, 0.45, st));
        }
        continue;
      }
      if (ch >= 2.0 &&
          ch <= 3.4 &&
          cw >= 0.6 &&
          cw <= 1.3 &&
          c.fill >= 0.25 &&
          c.fill <= 0.7 &&
          (c.cy - st.ys[2]).abs() <= 1.0 * s) {
        // A head just to the right means this is an accidental, not a rest.
        final accidental = heads.any(
          (hd) => hd.x0 > c.x1 - 0.2 * s && hd.x0 < c.x1 + 1.8 * s && hd.cy > c.y0 && hd.cy < c.y1,
        );
        if (!accidental) out.add(_Rest(c.cx, kPpq, 0.35, st));
      }
    }
    return out;
  }

  // --- barlines & measures --------------------------------------------------------------------

  List<double> _barlines(_Staff st, List<_Head> heads) {
    final s = st.s;
    final y0 = st.top.round(), y1 = st.bottom.round();
    final n = y1 - y0 + 1;
    final cand = <(int, int)>[];
    var a = -1;
    for (var x = st.x0; x <= st.x1 + 1; x++) {
      var on = false;
      if (x <= st.x1) {
        var c = 0;
        for (var y = y0; y <= y1; y++) {
          c += r.bits[y * w + x];
        }
        on = c >= 0.92 * n;
      }
      if (on && a < 0) a = x;
      if (!on && a >= 0) {
        cand.add((a, x - 1));
        a = -1;
      }
    }
    final out = <(int, int)>[];
    for (final (xa, xb) in cand) {
      if (xb - xa + 1 > math.max(0.6 * s, 4)) continue;
      final stem = heads.any(
        (hd) => hd.x0 - 0.35 * s <= xb && hd.x1 + 0.35 * s >= xa && hd.cy > st.top - 5 * s && hd.cy < st.bottom + 5 * s,
      );
      if (stem) continue;
      if (out.isNotEmpty && xa - out.last.$2 <= 1.2 * s) {
        out[out.length - 1] = (out.last.$1, xb);
      } else {
        out.add((xa, xb));
      }
    }
    return [
      for (final (xa, xb) in out)
        if ((xa + xb) / 2 > st.x0 + 1.5 * s && (xa + xb) / 2 > st.headerEnd) (xa + xb) / 2,
    ];
  }

  List<_MeasureDraft> _measures(List<_Staff> sys, List<_Head> heads, List<_Rest> rests, List<_Comp> comps) {
    final s = sys.first.s;
    var bars = _barlines(sys.first, heads);
    if (sys.length == 2) {
      final lower = _barlines(sys[1], heads);
      bars = [
        for (final x in bars)
          for (final y in lower)
            if ((x - y).abs() <= 0.6 * s) (x + y) / 2,
      ];
    }
    final x0 = sys.map((st) => st.x0).reduce(math.min).toDouble();
    final x1 = sys.map((st) => st.x1).reduce(math.max).toDouble();
    final bounds = [x0, ...bars.where((b) => b < x1 - 0.5 * s), x1];
    final headerEnd = sys.map((st) => st.headerEnd).reduce(math.max).toDouble();
    final top = sys.first.top - 2.5 * s, bottom = sys.last.bottom + 2.5 * s;
    final out = <_MeasureDraft>[];
    for (var i = 0; i + 1 < bounds.length; i++) {
      final a = bounds[i], bEnd = bounds[i + 1];
      final last = i + 2 == bounds.length;
      bool inM(double x) => x >= a && (last ? x <= bEnd + s : x < bEnd);
      final mh = heads.where((hd) => sys.contains(hd.staff) && inM(hd.cx)).toList();
      final mr = rests.where((rs) => sys.contains(rs.staff) && inM(rs.cx)).toList();
      final width = bEnd - math.max(a, i == 0 ? headerEnd : a);
      if (mh.isEmpty && mr.isEmpty && width < 3 * s) continue;
      final c = [_unrotate(a, top), _unrotate(bEnd, top), _unrotate(a, bottom), _unrotate(bEnd, bottom)];
      double nx(double v) => (v / w).clamp(0.0, 1.0);
      double ny(double v) => (v / h).clamp(0.0, 1.0);
      final md = _MeasureDraft(
        index,
        nx(c.map((p) => p.$1).reduce(math.min)),
        nx(c.map((p) => p.$1).reduce(math.max)),
        ny(c.map((p) => p.$2).reduce(math.min)),
        ny(c.map((p) => p.$2).reduce(math.max)),
        sys,
      );
      if (bars.isEmpty) md.flags.add('No barlines found on this system — measure boundaries guessed');
      for (final st in sys) {
        md.heads[st] = mh.where((hd) => hd.staff == st).toList()..sort((p, q) => p.cx.compareTo(q.cx));
        md.rests[st] = mr.where((rs) => rs.staff == st).toList();
      }
      if (settings.grandStaff && sys.length == 2) _pedalCandidates(md, sys[1], a, bEnd, comps, heads);
      out.add(md);
    }
    return out;
  }

  /// Very rough "Ped." / "✱" candidates below the lower staff. Always low confidence.
  void _pedalCandidates(_MeasureDraft md, _Staff st, double a, double bEnd, List<_Comp> comps, List<_Head> heads) {
    final s = st.s;
    final region =
        comps
            .where(
              (c) =>
                  c.y0 > st.bottom + 1.2 * s &&
                  c.y1 < st.bottom + 6 * s &&
                  c.cx >= a &&
                  c.cx < bEnd &&
                  c.area >= 3 &&
                  !heads.any((hd) => hd.x0 - s <= c.x1 && hd.x1 + s >= c.x0 && hd.y0 - s <= c.y1 && hd.y1 + s >= c.y0),
            )
            .toList()
          ..sort((p, q) => p.x0.compareTo(q.x0));
    final used = <_Comp>{};
    for (var i = 0; i < region.length; i++) {
      final first = region[i];
      if (used.contains(first)) continue;
      final group = [first];
      var end = first.x1;
      for (var j = i + 1; j < region.length; j++) {
        final c = region[j];
        if (c.x0 > end + 0.7 * s) break;
        if (c.y1 < first.y0 - s || c.y0 > first.y1 + s) continue;
        group.add(c);
        end = math.max(end, c.x1);
      }
      final gx0 = group.first.x0, gy0 = group.map((c) => c.y0).reduce(math.min);
      final gy1 = group.map((c) => c.y1).reduce(math.max);
      final gw = (end - gx0 + 1) / s, gh = (gy1 - gy0 + 1) / s;
      final lastC = group.reduce((p, q) => p.x1 > q.x1 ? p : q);
      final frac = ((gx0 - a) / (bEnd - a)).clamp(0.0, 0.999);
      if (group.length >= 3 &&
          group.length <= 6 &&
          gw >= 2.0 &&
          gw <= 5.5 &&
          gh >= 1.0 &&
          gh <= 2.8 &&
          lastC.w <= 0.6 * s &&
          lastC.h <= 0.6 * s &&
          first.h >= 0.7 * (gy1 - gy0 + 1)) {
        md.pedals.add((frac, PedalType.down, 0.3));
        used.addAll(group);
      } else if (group.length == 1 && _starLike(first, s)) {
        md.pedals.add((frac, PedalType.up, 0.25));
        used.add(first);
      }
    }
  }

  bool _starLike(_Comp c, double s) {
    final cw = c.w / s, ch = c.h / s;
    if (cw < 0.9 || cw > 2.4 || ch < 0.9 || ch > 2.4 || (cw - ch).abs() > 0.35 * math.max(cw, ch)) return false;
    if (c.fill < 0.25 || c.fill > 0.7) return false;
    final rad = 0.42 * math.min(c.w, c.h), cx = (c.x0 + c.x1) / 2, cy = (c.y0 + c.y1) / 2;
    var trans = 0, prev = -1;
    for (var i = 0; i <= 48; i++) {
      final a = i * 2 * math.pi / 48;
      final v = r.get((cx + rad * math.cos(a)).round(), (cy + rad * math.sin(a)).round());
      if (prev == 1 && v == 0) trans++;
      prev = v;
    }
    return trans >= 5;
  }
}

double _noteConf(_Head hd) {
  final snap = (1 - 1.3 * hd.snapErr).clamp(0.2, 1.0);
  var c = 0.95 * math.pow(hd.shape, 0.4) * math.pow(snap, 0.3) * math.pow(hd.durConf, 0.3);
  if (hd.accDetected) c *= 0.75;
  if (hd.cluster) c *= 0.7;
  if (hd.flags.contains('Many ledger lines — check octave')) c *= 0.85;
  return c.clamp(0.05, 0.95).toDouble();
}

String _beats(int ticks, TimeSignature ts) {
  final v = ticks / (kPpq * 4 / ts.beatType);
  return v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(2).replaceAll(RegExp(r'0+$'), '');
}

// ---------------------------------------------------------------------------------------------
// Timing / score assembly

void _assemble(Score score, List<_MeasureDraft> drafts, OmrSettings settings) {
  final len = settings.time.measureTicks(kPpq);
  for (var mi = 0; mi < drafts.length; mi++) {
    final md = drafts[mi];
    final start = mi * len;
    final flags = [...md.flags];
    var minConf = 0.95;
    var any = false;
    for (final st in md.staves) {
      final heads = md.heads[st] ?? const <_Head>[];
      final rests = md.rests[st] ?? const <_Rest>[];
      if (heads.isEmpty && rests.isEmpty) {
        final other = md.staves.any(
          (o) => o != st && ((md.heads[o]?.isNotEmpty ?? false) || (md.rests[o]?.isNotEmpty ?? false)),
        );
        if (other) {
          flags.add(
            'Nothing recognized on the ${st.staffNo == 1 ? 'upper' : 'lower'} staff — check for missed notes or rests',
          );
          minConf = math.min(minConf, 0.6);
        }
        continue;
      }
      any = true;
      final s = st.s;
      // Events: chords (heads close in x or sharing a stem) and rests, in x order.
      final events = <(double, List<_Head>, _Rest?)>[];
      for (final hd in heads) {
        if (events.isNotEmpty && events.last.$3 == null) {
          final g = events.last.$2;
          final close = (hd.cx - g.first.cx).abs() <= 0.8 * s;
          final shared = hd.stemX >= 0 && g.any((o) => o.stemX >= 0 && (o.stemX - hd.stemX).abs() <= 0.4 * s);
          if (close || shared) {
            g.add(hd);
            continue;
          }
        }
        events.add((hd.cx, [hd], null));
      }
      for (final rs in rests) {
        events.add((rs.cx, const [], rs));
      }
      events.sort((p, q) => p.$1.compareTo(q.$1));
      final onlyRest = events.length == 1 && events.first.$3 != null;
      final durs = <int>[];
      for (final e in events) {
        if (e.$3 != null) {
          final d = e.$3!.durTicks;
          durs.add(d < 0 ? (onlyRest ? len : 4 * kPpq) : d);
          continue;
        }
        final g = e.$2;
        final best = g.reduce((p, q) => _noteConf(p) >= _noteConf(q) ? p : q);
        if (g.any((o) => o.durTicks != best.durTicks)) {
          for (final o in g) {
            o.flags.add('Chord notes disagree on duration — check voices');
          }
        }
        durs.add(best.durTicks);
      }
      final sum = durs.fold<int>(0, (a, b) => a + b);
      final factor = sum > len ? len / sum : 1.0;
      if (sum != len) {
        final where = md.staves.length == 2 ? (st.staffNo == 1 ? ', upper staff' : ', lower staff') : '';
        flags.add("Rhythm doesn't add up (${_beats(sum, settings.time)} of ${_beats(len, settings.time)} beats$where)");
        minConf = math.min(minConf, 0.4);
      }
      // Accidentals last until the barline (per staff, per staff position).
      final carried = <int, int>{};
      var cum = 0;
      for (var i = 0; i < events.length; i++) {
        final onset = start + ((cum * factor) / 10).floor() * 10;
        cum += durs[i];
        final e = events[i];
        if (e.$3 != null) {
          score.rests.add(
            ScoreRest(
              startTick: onset,
              durationTicks: durs[i],
              staff: st.staffNo,
              measureIndex: mi,
              confidence: math.min(0.5, e.$3!.conf),
            ),
          );
          minConf = math.min(minConf, e.$3!.conf);
          continue;
        }
        for (final hd in e.$2) {
          final step = hd.diatonic % 7, octave = hd.diatonic ~/ 7 - 1;
          int alter;
          int? explicit;
          if (hd.accDetected && hd.accGuess != null) {
            alter = hd.accGuess!;
            explicit = alter;
            carried[hd.diatonic] = alter;
          } else if (carried.containsKey(hd.diatonic)) {
            alter = carried[hd.diatonic]!;
            hd.flags.add('Accidental carried from earlier in the measure');
          } else {
            alter = settings.key.alterFor(step);
          }
          hd.midi = Pitch.fromStep(step, alter, octave).clamp(0, 127);
          final conf = _noteConf(hd);
          minConf = math.min(minConf, conf);
          score.notes.add(
            ScoreNote(
              id: newId('n'),
              midi: hd.midi,
              startTick: onset,
              durationTicks: durs[i],
              staff: st.staffNo,
              hand: st.hand,
              measureIndex: mi,
              dots: hd.dot ? 1 : 0,
              accidental: explicit,
              confidence: conf,
              verified: false,
              flags: [
                ...{...hd.flags},
              ],
            ),
          );
        }
      }
    }
    if (!any) {
      flags.add('Nothing recognized in this measure — add notes or rests in review');
      minConf = 0.2;
    }
    for (final (frac, type, conf) in md.pedals) {
      score.pedals.add(
        PedalEvent(
          id: newId('p'),
          tick: start + ((frac * len) / 10).floor() * 10,
          type: type,
          confidence: math.min(0.35, conf),
          verified: false,
          source: 'omr',
        ),
      );
    }
    final rhythmBad = flags.any((f) => f.startsWith("Rhythm doesn't"));
    if (rhythmBad) score.issues.add(ScoreIssue("Rhythm doesn't add up in measure ${mi + 1}", measureIndex: mi));
    score.measures.add(
      Measure(
        index: mi,
        startTick: start,
        lengthTicks: len,
        number: '${mi + 1}',
        time: settings.time,
        key: settings.key,
        confidence: minConf,
        verified: false,
        flags: flags,
        page: md.page,
        x0: md.x0,
        x1: md.x1,
        y0: md.y0,
        y1: md.y1,
      ),
    );
  }
}
