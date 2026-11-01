import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/app_state.dart';
import '../../core/model/session.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Progress history for one piece: totals, accuracy trend, session list.
class HistoryScreen extends StatelessWidget {
  final String pieceId;
  const HistoryScreen({super.key, required this.pieceId});

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final piece = app.library.byId(pieceId);
    return Scaffold(
      appBar: AppBar(title: Text(piece?.title ?? 'History')),
      body: SafeArea(
        child: FutureBuilder<List<PracticeSession>>(
          future: app.library.sessions(pieceId),
          builder: (context, snap) {
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            final sessions = snap.data!.reversed.toList();
            if (sessions.isEmpty) {
              return const Center(child: Padding(padding: EdgeInsets.all(32), child: Text('No practice sessions yet. Your history will appear here.')));
            }
            final total = sessions.fold<int>(0, (a, s) => a + s.durationSec);
            final t = Theme.of(context).textTheme;
            return ListView(padding: const EdgeInsets.all(16), children: [
              Text('${sessions.length} sessions · ${formatDuration(total)} total', style: t.titleMedium),
              if (piece != null) Text('Progress ${(piece.progress * 100).round()}% (best accuracy per measure)', style: t.bodySmall),
              const SectionTitle('Pitch accuracy over time'),
              SizedBox(
                height: 140,
                child: Semantics(
                  label: 'Chart of pitch accuracy for the last ${sessions.length.clamp(0, 30)} sessions',
                  child: CustomPaint(
                    painter: _TrendPainter(sessions.reversed.take(30).toList(), Theme.of(context).colorScheme.primary, Theme.of(context).colorScheme.outlineVariant),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
              Text('Hollow points: estimate from microphone. Gaps: not enough reliable input.', style: t.bodySmall),
              const SectionTitle('Sessions'),
              for (final s in sessions)
                Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    leading: Icon(switch (s.input) { InputKind.midi => Icons.cable, InputKind.mic => Icons.mic_none, InputKind.none => Icons.hearing_disabled_outlined }),
                    title: Text('${formatDate(s.startedAt)} · ${formatDuration(s.durationSec)}'),
                    subtitle: Text([
                      s.mode == PracticeMode.wait ? 'Wait mode' : 'Follow along',
                      '${s.tempoPct.round()}%',
                      if (s.loopStart != null) 'm. ${s.loopStart! + 1}–${s.loopEnd! + 1}',
                      if (s.hands != HandsSelection.both) s.hands == HandsSelection.right ? 'RH' : 'LH',
                    ].join(' · ')),
                    trailing: Text(
                      s.lowQuality ? 'unclear' : s.pitchAccuracy == null ? '—' : '${(s.pitchAccuracy! * 100).round()}%',
                      style: t.titleMedium?.copyWith(color: s.lowQuality ? SlColors.unsure : null),
                    ),
                  ),
                ),
            ]);
          },
        ),
      ),
    );
  }
}

class _TrendPainter extends CustomPainter {
  final List<PracticeSession> sessions;
  final Color color;
  final Color grid;
  _TrendPainter(this.sessions, this.color, this.grid);

  @override
  void paint(Canvas canvas, Size size) {
    final g = Paint()..color = grid;
    for (final f in [0.0, 0.5, 1.0]) {
      final y = size.height - f * (size.height - 16) - 8;
      canvas.drawLine(Offset(28, y), Offset(size.width, y), g);
      final tp = TextPainter(text: TextSpan(text: '${(f * 100).round()}', style: TextStyle(color: grid, fontSize: 10)), textDirection: TextDirection.ltr)..layout();
      tp.paint(canvas, Offset(0, y - tp.height / 2));
    }
    if (sessions.isEmpty) return;
    final dx = sessions.length == 1 ? 0.0 : (size.width - 40) / (sessions.length - 1);
    Offset? prev;
    for (var i = 0; i < sessions.length; i++) {
      final s = sessions[i];
      final a = s.lowQuality ? null : s.pitchAccuracy;
      if (a == null) {
        prev = null;
        continue;
      }
      final p = Offset(34 + i * dx, size.height - a * (size.height - 16) - 8);
      if (prev != null) {
        canvas.drawLine(prev, p, Paint()
          ..color = color
          ..strokeWidth = 2);
      }
      final mic = s.input == InputKind.mic;
      canvas.drawCircle(p, 4.5, Paint()
        ..color = color
        ..style = mic ? PaintingStyle.stroke : PaintingStyle.fill
        ..strokeWidth = 2);
      prev = p;
    }
  }

  @override
  bool shouldRepaint(_TrendPainter o) => o.sessions != sessions;
}
