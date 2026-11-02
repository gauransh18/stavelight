import 'package:flutter/material.dart';

import '../../core/model/pitch.dart';
import '../../core/model/score.dart';
import '../theme.dart';

/// Horizontal key layout shared by the keyboard and the falling-note view so columns line up.
class KeyLayout {
  final int low; // MIDI, always a white key
  final int high; // MIDI, always a white key
  final double width;
  late final List<int> whites;
  late final double whiteW;

  KeyLayout(int low, int high, this.width)
      : low = Pitch.isBlack(low) ? low - 1 : low,
        high = Pitch.isBlack(high) ? high + 1 : high {
    whites = [for (var m = this.low; m <= this.high; m++) if (!Pitch.isBlack(m)) m];
    whiteW = width / whites.length;
  }

  /// Range covering [notes] with some padding, at least two octaves, clamped to 88 keys.
  factory KeyLayout.forNotes(Iterable<int> notes, double width, {int minSpan = 24}) {
    var lo = 60, hi = 72;
    if (notes.isNotEmpty) {
      lo = notes.reduce((a, b) => a < b ? a : b) - 2;
      hi = notes.reduce((a, b) => a > b ? a : b) + 2;
    }
    while (hi - lo < minSpan) {
      lo -= 1;
      if (hi - lo < minSpan) hi += 1;
    }
    return KeyLayout(lo.clamp(21, 108), hi.clamp(21, 108), width);
  }

  bool contains(int midi) => midi >= low && midi <= high;
  double get blackW => whiteW * 0.6;

  int _whiteIndex(int midi) {
    var i = 0;
    for (var m = low; m < midi; m++) {
      if (!Pitch.isBlack(m)) i++;
    }
    return i;
  }

  /// Left edge and width of a key's column.
  (double, double) column(int midi) {
    if (Pitch.isBlack(midi)) {
      final left = _whiteIndex(midi) * whiteW - blackW / 2;
      return (left, blackW);
    }
    return (_whiteIndex(midi) * whiteW, whiteW);
  }

  int? keyAt(Offset p, double height) {
    if (p.dy < height * 0.62) {
      for (var m = low; m <= high; m++) {
        if (!Pitch.isBlack(m)) continue;
        final (l, w) = column(m);
        if (p.dx >= l && p.dx <= l + w) return m;
      }
    }
    final i = (p.dx / whiteW).floor();
    return i >= 0 && i < whites.length ? whites[i] : null;
  }
}

enum KeyMark { target, played, wrong, uncertain }

class KeyState {
  final KeyMark mark;
  final Hand hand;
  const KeyState(this.mark, {this.hand = Hand.unassigned});
}

class KeyboardPainter extends CustomPainter {
  final KeyLayout layout;
  final Map<int, KeyState> states;
  final bool labels;
  final bool octaveLabels;
  final Brightness brightness;
  final bool highContrast;

  KeyboardPainter({
    required this.layout,
    required this.states,
    this.labels = true,
    this.octaveLabels = true,
    required this.brightness,
    this.highContrast = false,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final dark = brightness == Brightness.dark;
    final border = Paint()
      ..color = dark ? Colors.black : const Color(0xFF3A3A3A)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final whiteFill = Paint()..color = dark ? const Color(0xFFE9E6DF) : Colors.white;
    final blackFill = Paint()..color = const Color(0xFF1B1D1F);
    final h = size.height;
    final bh = h * 0.62;

    for (final m in layout.whites) {
      final (l, w) = layout.column(m);
      final r = Rect.fromLTWH(l, 0, w, h);
      canvas.drawRect(r, whiteFill);
      _mark(canvas, r, m, false);
      canvas.drawRect(r, border);
      if (labels && (Pitch.pitchClass(m) == 0 || w > 26)) {
        _label(canvas, Pitch.name(m, withOctave: octaveLabels && Pitch.pitchClass(m) == 0), Offset(l + w / 2, h - 14),
            // White only reads on solid fills; a target key keeps its pale tint, so keep the label dark.
            switch (states[m]?.mark) { null || KeyMark.target => const Color(0xFF555555), _ => Colors.white }, w);
      }
    }
    for (var m = layout.low; m <= layout.high; m++) {
      if (!Pitch.isBlack(m)) continue;
      final (l, w) = layout.column(m);
      final r = RRect.fromRectAndCorners(Rect.fromLTWH(l, 0, w, bh), bottomLeft: const Radius.circular(3), bottomRight: const Radius.circular(3));
      canvas.drawRRect(r, blackFill);
      _mark(canvas, r.outerRect, m, true);
    }
  }

  void _mark(Canvas canvas, Rect r, int m, bool black) {
    final s = states[m];
    if (s == null) return;
    final handColor = SlColors.hand(s.hand, brightness, highContrast: highContrast);
    final inset = r.deflate(black ? 2 : 3);
    switch (s.mark) {
      case KeyMark.played:
        canvas.drawRRect(RRect.fromRectAndRadius(inset, const Radius.circular(4)), Paint()..color = handColor);
      case KeyMark.target:
        // Outline + dot: upcoming key to press.
        canvas.drawRRect(
            RRect.fromRectAndRadius(inset, const Radius.circular(4)),
            Paint()
              ..color = handColor.withValues(alpha: 0.25)
              ..style = PaintingStyle.fill);
        canvas.drawCircle(Offset(r.center.dx, r.bottom - (black ? 10 : 30)), r.width * 0.18, Paint()..color = handColor);
      case KeyMark.wrong:
        canvas.drawRRect(RRect.fromRectAndRadius(inset, const Radius.circular(4)), Paint()..color = SlColors.bad.withValues(alpha: 0.85));
        _cross(canvas, Offset(r.center.dx, r.bottom - (black ? 12 : 32)), r.width * 0.2);
      case KeyMark.uncertain:
        canvas.drawRRect(
            RRect.fromRectAndRadius(inset, const Radius.circular(4)),
            Paint()
              ..color = SlColors.unsure.withValues(alpha: 0.6)
              ..style = PaintingStyle.fill);
        _label(canvas, '?', Offset(r.center.dx, r.bottom - (black ? 12 : 32)), Colors.white, r.width);
    }
  }

  void _cross(Canvas c, Offset o, double s) {
    final p = Paint()
      ..color = Colors.white
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    c.drawLine(o.translate(-s, -s), o.translate(s, s), p);
    c.drawLine(o.translate(s, -s), o.translate(-s, s), p);
  }

  void _label(Canvas c, String text, Offset center, Color color, double maxW) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: TextStyle(color: color, fontSize: (maxW * 0.38).clamp(8, 13), fontWeight: FontWeight.w600)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(c, center - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(KeyboardPainter old) => true;
}

/// Keyboard widget with optional tap-to-play (used for free play / manual note entry).
class PianoKeyboard extends StatelessWidget {
  final KeyLayout Function(double width) layoutFor;
  final Map<int, KeyState> states;
  final bool labels;
  final bool octaveLabels;
  final bool highContrast;
  final void Function(int midi)? onKey;

  const PianoKeyboard({
    super.key,
    required this.layoutFor,
    required this.states,
    this.labels = true,
    this.octaveLabels = true,
    this.highContrast = false,
    this.onKey,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final layout = layoutFor(c.maxWidth);
      final held = states.entries.where((e) => e.value.mark == KeyMark.played).map((e) => Pitch.spokenName(e.key)).join(', ');
      return Semantics(
        label: 'Piano keyboard${held.isEmpty ? '' : ', playing $held'}',
        child: GestureDetector(
          onTapDown: onKey == null
              ? null
              : (d) {
                  final k = layout.keyAt(d.localPosition, c.maxHeight);
                  if (k != null) onKey!(k);
                },
          child: CustomPaint(
            size: Size(c.maxWidth, c.maxHeight),
            painter: KeyboardPainter(
              layout: layout,
              states: states,
              labels: labels,
              octaveLabels: octaveLabels,
              brightness: Theme.of(context).brightness,
              highContrast: highContrast,
            ),
          ),
        ),
      );
    });
  }
}
