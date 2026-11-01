import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// 1-bit page. [bits] holds 1 for ink, 0 for paper, row-major.
class BinaryImage {
  final int width;
  final int height;
  final Uint8List bits;

  BinaryImage(this.width, this.height, [Uint8List? bits]) : bits = bits ?? Uint8List(width * height);

  bool inside(int x, int y) => x >= 0 && y >= 0 && x < width && y < height;

  /// Ink at (x, y); outside the page counts as paper.
  int get(int x, int y) => inside(x, y) ? bits[y * width + x] : 0;

  void set(int x, int y, int v) {
    if (inside(x, y)) bits[y * width + x] = v;
  }

  int get inkCount {
    var n = 0;
    for (final b in bits) {
      n += b;
    }
    return n;
  }

  BinaryImage copy() => BinaryImage(width, height, Uint8List.fromList(bits));

  /// Debug view: ink black on white.
  img.Image toImage() {
    final g = Uint8List(width * height);
    for (var i = 0; i < g.length; i++) {
      g[i] = bits[i] == 1 ? 0 : 255;
    }
    return img.Image.fromBytes(width: width, height: height, bytes: g.buffer, numChannels: 1);
  }
}

/// Luminance 0..255 per pixel (alpha composited over white).
Uint8List grayBytes(img.Image src) {
  final w = src.width, h = src.height, n = w * h;
  final out = Uint8List(n);
  final nc = src.numChannels;
  if (src.format == img.Format.uint8 && !src.hasPalette && src.rowStride == w * nc) {
    final d = src.toUint8List();
    for (var i = 0, j = 0; i < n; i++, j += nc) {
      int lum, a = 255;
      switch (nc) {
        case 1:
          lum = d[j];
        case 2:
          lum = d[j];
          a = d[j + 1];
        case 3:
          lum = (d[j] * 299 + d[j + 1] * 587 + d[j + 2] * 114) ~/ 1000;
        default:
          lum = (d[j] * 299 + d[j + 1] * 587 + d[j + 2] * 114) ~/ 1000;
          a = d[j + 3];
      }
      out[i] = a == 255 ? lum : (lum * a + 255 * (255 - a)) ~/ 255;
    }
    return out;
  }
  var i = 0;
  for (final p in src) {
    final a = src.hasAlpha ? p.aNormalized : 1.0;
    out[i++] = ((p.luminanceNormalized * a + (1 - a)) * 255).round().clamp(0, 255);
  }
  return out;
}

img.Image _fromGray(Uint8List g, int w, int h) =>
    img.Image.fromBytes(width: w, height: h, bytes: g.buffer, numChannels: 1);

/// Downscale so the longer side is at most [maxSide]. Never upscales.
img.Image limitSize(img.Image src, {int maxSide = 2600}) {
  final longer = math.max(src.width, src.height);
  if (longer <= maxSide) return src;
  final f = maxSide / longer;
  return img.copyResize(
    src,
    width: math.max(1, (src.width * f).round()),
    height: math.max(1, (src.height * f).round()),
    interpolation: img.Interpolation.average,
  );
}

/// Grayscale, optional 1%–99% level stretch, then contrast around mid-gray. Returns a 1-channel image.
img.Image enhanceForOmr(img.Image src, {double contrast = 1.0, bool autoLevel = true}) {
  final g = grayBytes(src);
  var lo = 0, hi = 255;
  if (autoLevel && g.isNotEmpty) {
    final hist = List<int>.filled(256, 0);
    for (final v in g) {
      hist[v]++;
    }
    final cut = (g.length * 0.01).floor();
    var acc = 0;
    while (lo < 255 && acc + hist[lo] <= cut) {
      acc += hist[lo++];
    }
    acc = 0;
    while (hi > 0 && acc + hist[hi] <= cut) {
      acc += hist[hi--];
    }
    if (hi - lo < 16) {
      lo = 0;
      hi = 255;
    }
  }
  final lut = Uint8List(256);
  for (var v = 0; v < 256; v++) {
    final n = ((v - lo) / (hi - lo)).clamp(0.0, 1.0) * 255;
    lut[v] = ((n - 128) * contrast + 128).round().clamp(0, 255);
  }
  for (var i = 0; i < g.length; i++) {
    g[i] = lut[g[i]];
  }
  return _fromGray(g, src.width, src.height);
}

/// Rotate by quarter turns clockwise (negative = counter-clockwise).
img.Image rotateQuarter(img.Image src, int quarterTurns) {
  final q = quarterTurns % 4;
  return q == 0 ? src.clone() : img.copyRotate(src, angle: q * 90);
}

/// Crop to the rectangle given as fractions (0..1) of width/height.
img.Image cropNormalized(img.Image src, double l, double t, double r, double b) {
  final x0 = (math.min(l, r).clamp(0.0, 1.0) * src.width).floor();
  final y0 = (math.min(t, b).clamp(0.0, 1.0) * src.height).floor();
  final x1 = (math.max(l, r).clamp(0.0, 1.0) * src.width).ceil();
  final y1 = (math.max(t, b).clamp(0.0, 1.0) * src.height).ceil();
  return img.copyCrop(src, x: x0, y: y0, width: math.max(1, x1 - x0), height: math.max(1, y1 - y0));
}

/// Map the quadrilateral [cornersNormalized] (TL, TR, BR, BL as fractions of the page) to an upright
/// rectangle using a projective transform (bilinear sampling). Output size follows the quad's edge lengths.
img.Image perspectiveCorrect(img.Image src, List<(double, double)> cornersNormalized) {
  if (cornersNormalized.length != 4) throw ArgumentError('Need 4 corners (TL, TR, BR, BL)');
  final p = [for (final c in cornersNormalized) (c.$1 * (src.width - 1), c.$2 * (src.height - 1))];
  double dist((double, double) a, (double, double) b) => math.sqrt(math.pow(a.$1 - b.$1, 2) + math.pow(a.$2 - b.$2, 2));
  final outW = math.max(dist(p[0], p[1]), dist(p[3], p[2])).round().clamp(2, 8000);
  final outH = math.max(dist(p[0], p[3]), dist(p[1], p[2])).round().clamp(2, 8000);

  // Unit square -> quad (Heckbert). (0,0)=TL, (1,0)=TR, (1,1)=BR, (0,1)=BL.
  final x0 = p[0].$1, y0 = p[0].$2, x1 = p[1].$1, y1 = p[1].$2;
  final x2 = p[2].$1, y2 = p[2].$2, x3 = p[3].$1, y3 = p[3].$2;
  final dx1 = x1 - x2, dx2 = x3 - x2, dx3 = x0 - x1 + x2 - x3;
  final dy1 = y1 - y2, dy2 = y3 - y2, dy3 = y0 - y1 + y2 - y3;
  final den = dx1 * dy2 - dx2 * dy1;
  var g = 0.0, h = 0.0;
  if ((dx3.abs() > 1e-9 || dy3.abs() > 1e-9) && den.abs() > 1e-12) {
    g = (dx3 * dy2 - dx2 * dy3) / den;
    h = (dx1 * dy3 - dx3 * dy1) / den;
  }
  final a = x1 - x0 + g * x1, b = x3 - x0 + h * x3, c = x0;
  final d = y1 - y0 + g * y1, e = y3 - y0 + h * y3, f = y0;

  final dst = img.Image(width: outW, height: outH, numChannels: src.numChannels);
  for (var y = 0; y < outH; y++) {
    final v = y / (outH - 1);
    for (var x = 0; x < outW; x++) {
      final u = x / (outW - 1);
      final w = g * u + h * v + 1;
      final sx = (a * u + b * v + c) / w, sy = (d * u + e * v + f) / w;
      dst.setPixel(x, y, src.getPixelInterpolate(sx, sy, interpolation: img.Interpolation.linear));
    }
  }
  return dst;
}

/// Otsu threshold over a 256-bin histogram.
int otsuThreshold(Uint8List gray) {
  final hist = List<int>.filled(256, 0);
  for (final v in gray) {
    hist[v]++;
  }
  final total = gray.length;
  var sum = 0.0;
  for (var i = 0; i < 256; i++) {
    sum += i * hist[i];
  }
  var sumB = 0.0, wB = 0, best = 0.0, thr = 128;
  for (var t = 0; t < 256; t++) {
    wB += hist[t];
    if (wB == 0) continue;
    final wF = total - wB;
    if (wF == 0) break;
    sumB += t * hist[t];
    final mB = sumB / wB, mF = (sum - sumB) / wF;
    final between = wB * wF * (mB - mF) * (mB - mF);
    if (between > best) {
      best = between;
      thr = t;
    }
  }
  return thr;
}

/// Sauvola adaptive threshold (handles uneven lighting in photos), backed by a global Otsu floor
/// so solid dark regions larger than the window stay ink. Window ~1/50 of the longer side.
BinaryImage binarize(img.Image gray, {double k = 0.25, int? window}) {
  final w = gray.width, h = gray.height;
  final g = grayBytes(gray);
  final out = BinaryImage(w, h);
  if (w == 0 || h == 0) return out;
  final otsu = otsuThreshold(g);
  final dark = otsu * 0.5;
  final r = ((window ?? math.max(25, math.max(w, h) ~/ 50)) ~/ 2).clamp(3, 200);

  // Sliding box sums: horizontal window sums per row, accumulated vertically per column.
  final colSum = Float64List(w), colSq = Float64List(w);
  final rowS = Float64List(w), rowQ = Float64List(w);
  void hsum(int y, double sign) {
    final base = y * w;
    var s = 0.0, q = 0.0;
    for (var x = 0; x <= math.min(r, w - 1); x++) {
      final v = g[base + x];
      s += v;
      q += v * v;
    }
    for (var x = 0; x < w; x++) {
      rowS[x] = s;
      rowQ[x] = q;
      final add = x + r + 1, sub = x - r;
      if (add < w) {
        final v = g[base + add];
        s += v;
        q += v * v;
      }
      if (sub >= 0) {
        final v = g[base + sub];
        s -= v;
        q -= v * v;
      }
    }
    for (var x = 0; x < w; x++) {
      colSum[x] += sign * rowS[x];
      colSq[x] += sign * rowQ[x];
    }
  }

  for (var y = 0; y <= math.min(r, h - 1); y++) {
    hsum(y, 1);
  }
  for (var y = 0; y < h; y++) {
    final rows = math.min(h - 1, y + r) - math.max(0, y - r) + 1;
    final base = y * w;
    for (var x = 0; x < w; x++) {
      final cols = math.min(w - 1, x + r) - math.max(0, x - r) + 1;
      final n = rows * cols;
      final m = colSum[x] / n;
      final varc = colSq[x] / n - m * m;
      final sd = varc > 0 ? math.sqrt(varc) : 0.0;
      final t = m * (1 + k * (sd / 128 - 1));
      final v = g[base + x];
      if (v < t || v < dark) out.bits[base + x] = 1;
    }
    if (y + r + 1 < h) hsum(y + r + 1, 1);
    if (y - r >= 0) hsum(y - r, -1);
  }
  return out;
}
