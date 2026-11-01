import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Raw grayscale canvas for drawing synthetic score pages (no anti-aliasing, exact geometry).
class SynthPage {
  final int w, h;
  final Uint8List g;
  SynthPage(this.w, this.h) : g = Uint8List(w * h)..fillRange(0, w * h, 255);

  void px(int x, int y, [int v = 0]) {
    if (x >= 0 && y >= 0 && x < w && y < h) g[y * w + x] = v;
  }

  /// Filled rectangle covering [x0, x1) × [y0, y1).
  void rect(num x0, num y0, num x1, num y1, [int v = 0]) {
    for (var y = y0.round(); y < y1.round(); y++) {
      for (var x = x0.round(); x < x1.round(); x++) {
        px(x, y, v);
      }
    }
  }

  void ellipse(double cx, double cy, double rx, double ry, [int v = 0]) {
    for (var y = (cy - ry).floor(); y <= (cy + ry).ceil(); y++) {
      for (var x = (cx - rx).floor(); x <= (cx + rx).ceil(); x++) {
        final dx = (x - cx) / rx, dy = (y - cy) / ry;
        if (dx * dx + dy * dy <= 1) px(x, y, v);
      }
    }
  }

  /// Horizontal line of thickness [t] centred on [y].
  void hline(double y, double x0, double x1, int t) => rect(x0, (y - t / 2).round(), x1, (y - t / 2).round() + t);

  img.Image toImage() => img.Image.fromBytes(width: w, height: h, bytes: Uint8List.fromList(g).buffer, numChannels: 1);
}

enum Stem { up, down, none }

/// Draws piano notation with staff spacing [s] (px). Positions are half-spaces above the bottom line.
class ScoreDrawer {
  final SynthPage p;
  final double s;
  final int t;
  ScoreDrawer(this.p, {this.s = 20, this.t = 2});

  double y(double top, int pos) => top + 4 * s - pos * s / 2;

  void staff(double top, double x0, double x1) {
    for (var i = 0; i < 5; i++) {
      p.hline(top + i * s, x0, x1, t);
    }
  }

  void barline(double x, double top, double bottom) => p.rect(x, top - t / 2, x + 2, bottom + t / 2);

  /// Clef-like blob plus "time signature" blocks at the staff start (header).
  void header(double top, double x0) {
    p.rect(x0 + 10, top - 1.5 * s, x0 + 22, top + 5.5 * s);
    p.ellipse(x0 + 16, top + 2.5 * s, 0.9 * s, 0.9 * s);
    p.rect(x0 + 45, top + 0.2 * s, x0 + 60, top + 1.8 * s);
    p.rect(x0 + 45, top + 2.2 * s, x0 + 60, top + 3.8 * s);
  }

  /// Returns the stem tip (x, y) when a stem is drawn.
  (double, double) note(
    double top,
    int pos,
    double x, {
    bool hollow = false,
    bool whole = false,
    Stem stem = Stem.up,
    bool dot = false,
    double stemLen = 3.5,
    bool flag = false,
  }) {
    final cy = y(top, pos);
    final rx = whole ? 0.85 * s : 0.65 * s, ry = whole ? 0.55 * s : 0.5 * s;
    p.ellipse(x, cy, rx, ry);
    if (hollow || whole) p.ellipse(x, cy, whole ? 0.45 * s : 0.42 * s, whole ? 0.3 * s : 0.27 * s, 255);
    if (pos < 0) {
      for (var k = -2; k >= pos; k -= 2) {
        p.hline(y(top, k), x - 0.95 * s, x + 0.95 * s, t);
      }
    }
    if (pos > 8) {
      for (var k = 10; k <= pos; k += 2) {
        p.hline(y(top, k), x - 0.95 * s, x + 0.95 * s, t);
      }
    }
    if (dot) p.ellipse(x + rx + 0.6 * s, (pos.isEven ? cy - s / 2 : cy), 0.2 * s, 0.2 * s);
    var tip = (x, cy);
    if (stem == Stem.up) {
      p.rect(x + rx - 2, cy - stemLen * s, x + rx, cy);
      tip = (x + rx - 1, cy - stemLen * s);
    } else if (stem == Stem.down) {
      p.rect(x - rx, cy, x - rx + 2, cy + stemLen * s);
      tip = (x - rx + 1, cy + stemLen * s);
    }
    if (flag && stem != Stem.none) {
      final dir = stem == Stem.up ? 1 : -1;
      for (var i = 0; i <= 24; i++) {
        final u = i / 24;
        p.ellipse(tip.$1 + 0.9 * s * math.sin(u * math.pi / 2), tip.$2 + dir * 2.2 * s * u, 0.22 * s, 0.22 * s);
      }
    }
    return tip;
  }

  /// Beam of thickness 0.5 s between two stem tips (stems up: beam hangs below the tips).
  void beam((double, double) a, (double, double) b, {bool up = true}) {
    for (var x = a.$1.round() - 1; x <= b.$1.round() + 1; x++) {
      final u = ((x - a.$1) / (b.$1 - a.$1)).clamp(0.0, 1.0);
      final yy = a.$2 + (b.$2 - a.$2) * u;
      final y0 = up ? yy : yy - 0.5 * s;
      p.rect(x, y0, x + 1, y0 + 0.5 * s);
    }
  }
}

/// Rotate a page by [deg] around its centre, filling with white.
img.Image rotateWhite(img.Image src, double deg) {
  final w = src.width, h = src.height;
  final out = img.Image(width: w, height: h, numChannels: 1);
  final a = deg * math.pi / 180, ca = math.cos(a), sa = math.sin(a);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final dx = x - w / 2, dy = y - h / 2;
      final xs = (w / 2 + dx * ca + dy * sa).round(), ys = (h / 2 - dx * sa + dy * ca).round();
      final v = (xs >= 0 && ys >= 0 && xs < w && ys < h) ? src.getPixel(xs, ys).r.toInt() : 255;
      out.setPixelRgb(x, y, v, v, v);
    }
  }
  return out;
}

/// Grand-staff test page (1600 × 800, s = 20). Upper staff top y = 200, lower staff top y = 400.
/// Measures (4/4):
///  1  treble: q G4 | q chord G4+D5 | half A4      bass: whole C3
///  2  treble: 8th E4 + 8th G4 (beamed) | dotted q A4 | 8th C5 (flag) | q F4
///     bass:   q F3 (stem down) | q D3 (stem down) | half rest
///  3  treble: q C4 (ledger) | q G4  (incomplete: 2 of 4 beats)
///     bass:   q G2 | q B2 | half D3
SynthPage grandStaffPage() {
  final p = SynthPage(1600, 800);
  final d = ScoreDrawer(p);
  const up = 200.0, lo = 400.0;
  d.staff(up, 100, 1502);
  d.staff(lo, 100, 1502);
  for (final x in [100.0, 600.0, 1050.0, 1500.0]) {
    d.barline(x, up, lo + 80);
  }
  d.header(up, 100);
  d.header(lo, 100);
  // measure 1
  d.note(up, 2, 250);
  d.note(up, 6, 340, stem: Stem.none);
  d.note(up, 2, 340, stemLen: 5.5);
  d.note(up, 3, 450, hollow: true);
  d.note(lo, 3, 330, whole: true, stem: Stem.none);
  // measure 2
  final a = d.note(up, 0, 650), b = d.note(up, 2, 720);
  d.beam(a, b);
  d.note(up, 3, 810, dot: true);
  d.note(up, 5, 900, flag: true);
  d.note(up, 1, 980);
  d.note(lo, 6, 660, stem: Stem.down);
  d.note(lo, 4, 760, stem: Stem.down);
  p.rect(870, lo + 30, 894, lo + 40); // half rest sitting on the middle line
  // measure 3
  d.note(up, -2, 1120);
  d.note(up, 2, 1220);
  d.note(lo, 0, 1110);
  d.note(lo, 2, 1200);
  d.note(lo, 4, 1330, hollow: true, stem: Stem.down);
  return p;
}
