import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/model/pitch.dart';
import '../../core/model/score.dart';
import '../../core/practice/matcher.dart';
import '../../core/practice/timeline.dart';
import '../theme.dart';
import 'keyboard.dart';

/// Width reserved at the left of the falling view and keyboard for the pedal lane.
const double kPedalLaneWidth = 40;

/// Falling-note view. Bars fall toward the keyboard; the bar length is the expected key-hold.
/// A thin dashed tail above a bar shows sound sustained by the pedal (not part of the key-hold).
class FallingNotesPainter extends CustomPainter {
  final PracticeTimeline timeline;
  final double Function() position;
  final KeyLayout Function(double width) layoutFor;
  final Map<String, NoteResult> results;
  final double pixelsPerSecond;
  final bool noteNames;
  final bool fingers;
  final bool pedalLane;
  final bool effects;
  final bool highContrast;
  final Brightness brightness;
  final double? loopStart;
  final double? loopEnd;

  FallingNotesPainter({
    required Listenable repaint,
    required this.timeline,
    required this.position,
    required this.layoutFor,
    required this.results,
    this.pixelsPerSecond = 160,
    this.noteNames = true,
    this.fingers = true,
    this.pedalLane = true,
    this.effects = true,
    this.highContrast = false,
    required this.brightness,
    this.loopStart,
    this.loopEnd,
  }) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    final dark = brightness == Brightness.dark;
    final pos = position();
    final layout = layoutFor(size.width - kPedalLaneWidth);
    final h = size.height;
    final visibleSec = h / pixelsPerSecond;
    double yOf(double t) => h - (t - pos) * pixelsPerSecond;
    canvas.clipRect(Offset.zero & size);

    canvas.drawRect(Offset.zero & size, Paint()..color = dark ? const Color(0xFF12191C) : const Color(0xFFF1EEE6));

    // Black-key column shading for orientation.
    canvas.save();
    canvas.translate(kPedalLaneWidth, 0);
    final shade = Paint()..color = (dark ? Colors.white : Colors.black).withValues(alpha: 0.035);
    for (var m = layout.low; m <= layout.high; m++) {
      if (!Pitch.isBlack(m)) continue;
      final (l, w) = layout.column(m);
      canvas.drawRect(Rect.fromLTWH(l, 0, w, h), shade);
    }
    for (final m in layout.whites) {
      if (Pitch.pitchClass(m) != 0) continue;
      final (l, _) = layout.column(m);
      canvas.drawLine(Offset(l, 0), Offset(l, h), Paint()..color = (dark ? Colors.white : Colors.black).withValues(alpha: 0.08));
    }
    canvas.restore();

    // Loop range shading outside the loop.
    if (loopStart != null && loopEnd != null) {
      final dim = Paint()..color = (dark ? Colors.black : Colors.white).withValues(alpha: 0.45);
      final yEnd = yOf(loopEnd!);
      if (yEnd > 0) canvas.drawRect(Rect.fromLTRB(0, 0, size.width, yEnd), dim);
    }

    // Beat and measure lines.
    final beatPaint = Paint()..color = (dark ? Colors.white : Colors.black).withValues(alpha: 0.06);
    final barPaint = Paint()
      ..color = (dark ? Colors.white : Colors.black).withValues(alpha: 0.22)
      ..strokeWidth = 1.2;
    for (final b in timeline.beats) {
      if (b.time < pos - 0.5) continue;
      if (b.time > pos + visibleSec) break;
      final y = yOf(b.time);
      canvas.drawLine(Offset(kPedalLaneWidth, y), Offset(size.width, y), b.downbeat ? barPaint : beatPaint);
      if (b.downbeat) {
        _text(canvas, '${b.measure + 1}', Offset(kPedalLaneWidth + 4, y - 14), 10,
            (dark ? Colors.white : Colors.black).withValues(alpha: 0.5));
      }
    }

    if (pedalLane) _paintPedal(canvas, size, pos, yOf, dark);

    // Notes.
    canvas.save();
    canvas.translate(kPedalLaneWidth, 0);
    for (final n in timeline.notes) {
      if (n.soundEnd < pos - 0.3) continue;
      if (n.start > pos + visibleSec) break;
      if (!layout.contains(n.midi)) continue;
      _paintNote(canvas, layout, n, yOf, pos, dark);
    }
    canvas.restore();

    // Hit line.
    canvas.drawLine(Offset(kPedalLaneWidth, h - 1), Offset(size.width, h - 1), Paint()
      ..color = SlColors.brass
      ..strokeWidth = 2);
  }

  void _paintNote(Canvas canvas, KeyLayout layout, ExpectedNote n, double Function(double) yOf, double pos, bool dark) {
    final (left, width) = layout.column(n.midi);
    final color = SlColors.hand(n.hand, brightness, highContrast: highContrast);
    final bottom = yOf(n.start);
    final top = yOf(n.end);
    final rect = Rect.fromLTRB(left + 1.5, math.min(top, bottom - 6), left + width - 1.5, bottom);
    final r = n.hand == Hand.left ? const Radius.circular(2) : const Radius.circular(7);
    final rr = RRect.fromRectAndRadius(rect, r);

    // Pedal-sustained sound after key release: dashed thin tail, visually distinct from the key-hold bar.
    if (n.soundEnd > n.end + 0.05) {
      final tailTop = yOf(n.soundEnd);
      final x = rect.center.dx;
      final p = Paint()
        ..color = color.withValues(alpha: 0.45)
        ..strokeWidth = 2;
      for (var y = rect.top; y > tailTop; y -= 8) {
        canvas.drawLine(Offset(x, y), Offset(x, math.max(tailTop, y - 4)), p);
      }
    }

    final res = results[n.noteId];
    final outcome = res?.outcome ?? NoteOutcome.pending;
    if (!n.active) {
      canvas.drawRRect(rr, Paint()
        ..color = color.withValues(alpha: 0.55)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5);
    } else {
      final fill = Paint()..color = outcome == NoteOutcome.pending ? color : color.withValues(alpha: 0.55);
      canvas.drawRRect(rr, fill);
      if (n.hand == Hand.left) _hatch(canvas, rr, dark);
      final uncertainSource = !n.verified && n.confidence < 0.75;
      if (uncertainSource) {
        canvas.drawRRect(rr.deflate(1), Paint()
          ..color = SlColors.warn
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2);
      }
      if (effects && res != null && res.isHit && res.onAt != null && pos - res.onAt! < 0.35) {
        final a = (1 - (pos - res.onAt!) / 0.35).clamp(0.0, 1.0);
        canvas.drawRRect(rr.inflate(4 * a), Paint()
          ..color = SlColors.good.withValues(alpha: 0.5 * a)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6));
      }
    }

    final labelColor = n.active ? Colors.white : color;
    if (noteNames && width >= 14 && rect.height >= 16) {
      _text(canvas, Pitch.name(n.midi, withOctave: width >= 22), Offset(rect.center.dx, rect.bottom - 12), (width * 0.42).clamp(8, 12), labelColor, center: true);
    }
    if (fingers && n.finger != null && rect.height >= 30) {
      _text(canvas, '${n.finger}', Offset(rect.center.dx, rect.top + 9), 11, labelColor, center: true, bold: true);
    }
    if (n.active && outcome != NoteOutcome.pending) _outcomeBadge(canvas, Offset(rect.center.dx, rect.bottom + 9), outcome);
  }

  void _hatch(Canvas canvas, RRect rr, bool dark) {
    canvas.save();
    canvas.clipRRect(rr);
    final p = Paint()
      ..color = Colors.white.withValues(alpha: 0.22)
      ..strokeWidth = 2;
    final r = rr.outerRect;
    for (var x = r.left - r.height; x < r.right; x += 7) {
      canvas.drawLine(Offset(x, r.bottom), Offset(x + r.height, r.top), p);
    }
    canvas.restore();
  }

  void _outcomeBadge(Canvas canvas, Offset c, NoteOutcome o) {
    final (color, kind) = switch (o) {
      NoteOutcome.correct || NoteOutcome.early || NoteOutcome.late => (SlColors.good, 0),
      NoteOutcome.wrongPitch || NoteOutcome.octaveMismatch || NoteOutcome.missed => (SlColors.bad, 1),
      _ => (SlColors.unsure, 2),
    };
    canvas.drawCircle(c, 7, Paint()..color = color);
    final p = Paint()
      ..color = Colors.white
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    if (kind == 0) {
      canvas.drawPath(Path()
        ..moveTo(c.dx - 3.5, c.dy)
        ..lineTo(c.dx - 1, c.dy + 2.5)
        ..lineTo(c.dx + 3.5, c.dy - 2.5), p);
    } else if (kind == 1) {
      canvas.drawLine(c.translate(-3, -3), c.translate(3, 3), p);
      canvas.drawLine(c.translate(3, -3), c.translate(-3, 3), p);
    } else {
      _text(canvas, '?', c.translate(0, -1), 10, Colors.white, center: true, bold: true);
    }
    if (o == NoteOutcome.early || o == NoteOutcome.late) {
      _text(canvas, o == NoteOutcome.early ? '‹' : '›', c.translate(11, -1), 12, color, center: true, bold: true);
    }
  }

  void _paintPedal(Canvas canvas, Size size, double pos, double Function(double) yOf, bool dark) {
    final laneBg = Paint()..color = (dark ? Colors.white : Colors.black).withValues(alpha: 0.05);
    canvas.drawRect(Rect.fromLTWH(0, 0, kPedalLaneWidth - 4, size.height), laneBg);
    double? downAt;
    var downCertain = true;
    void drawSpan(double from, double to, bool certain) {
      final r = Rect.fromLTRB(8, yOf(to).clamp(-10, size.height + 10), kPedalLaneWidth - 12, yOf(from).clamp(-10, size.height + 10));
      if (r.height <= 0) return;
      final paint = Paint()..color = SlColors.brass.withValues(alpha: certain ? 0.75 : 0.3);
      canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(4)), paint);
      if (!certain) {
        canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(4)), Paint()
          ..color = SlColors.brass
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1);
        _text(canvas, '?', Offset(r.center.dx, r.bottom - 10), 10, SlColors.brass, center: true, bold: true);
      }
    }

    for (final p in timeline.pedals) {
      if (p.down) {
        if (downAt != null) drawSpan(downAt, p.time, downCertain);
        downAt = p.time;
        downCertain = p.certain;
      } else if (downAt != null) {
        drawSpan(downAt, p.time, downCertain && p.certain);
        downAt = null;
      }
    }
    if (downAt != null) drawSpan(downAt, timeline.duration, downCertain);
    _text(canvas, 'Ped', Offset((kPedalLaneWidth - 4) / 2, 10), 9, (dark ? Colors.white : Colors.black).withValues(alpha: 0.6), center: true);
  }

  void _text(Canvas c, String s, Offset o, double size, Color color, {bool center = false, bool bold = false}) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: TextStyle(color: color, fontSize: size, fontWeight: bold ? FontWeight.w700 : FontWeight.w600)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(c, center ? o - Offset(tp.width / 2, tp.height / 2) : o);
  }

  @override
  bool shouldRepaint(FallingNotesPainter old) =>
      old.timeline != timeline ||
      old.noteNames != noteNames ||
      old.pedalLane != pedalLane ||
      old.brightness != brightness ||
      old.pixelsPerSecond != pixelsPerSecond ||
      old.loopStart != loopStart ||
      old.loopEnd != loopEnd;
}
