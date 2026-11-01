import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:stavelight/app/app_state.dart';
import 'package:stavelight/core/import/import_types.dart';
import 'package:stavelight/core/model/pitch.dart';
import 'package:stavelight/core/model/score.dart';
import 'package:stavelight/ui/render/staff_view.dart';
import 'package:stavelight/ui/review/review_screen.dart';
import 'package:stavelight/ui/theme.dart';

Score _score({double conf = 1.0}) => Score(
      title: 'Etude',
      origin: ScoreOrigin.musicxml,
      measures: [
        for (var i = 0; i < 2; i++)
          Measure(index: i, startTick: i * 1920, lengthTicks: 1920, number: '${i + 1}', time: const TimeSignature(4, 4), key: const KeySignature(0)),
      ],
      notes: [
        ScoreNote(id: 'n1', midi: 72, startTick: 0, durationTicks: 480, hand: Hand.right),
        ScoreNote(id: 'n2', midi: 76, startTick: 480, durationTicks: 480, hand: Hand.right, confidence: conf),
        ScoreNote(id: 'n3', midi: 48, startTick: 0, durationTicks: 1920, staff: 2, hand: Hand.left),
      ],
    );

void main() {
  late Directory dir;
  late AppState app;

  setUp(() => dir = Directory.systemTemp.createTempSync('sl_review_test'));
  tearDown(() => dir.deleteSync(recursive: true));

  Future<String> addPiece(WidgetTester tester, Score score) async {
    late String id;
    await tester.runAsync(() async {
      app = await AppState.create(dir);
      id = (await app.library.addPiece(originals: [('etude.musicxml', Uint8List(8))], format: ImportFormat.musicxml, score: score)).id;
    });
    return id;
  }

  Future<void> pumpScreen(WidgetTester tester, String id, {VoidCallback? onPractice}) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
        value: app,
        child: MaterialApp(theme: buildTheme(Brightness.light), home: ReviewScreen(pieceId: id, onPractice: onPractice)),
      ));
      for (var i = 0; i < 100 && find.byType(CircularProgressIndicator).evaluate().isNotEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await tester.pump();
      }
    });
    await tester.pump();
  }

  Future<void> disposeAndFlush(WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const SizedBox());
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
  }

  testWidgets('tap a note, move it up an octave, undo and redo, autosave on leave', (tester) async {
    final score = _score();
    final id = await addPiece(tester, score);
    await pumpScreen(tester, id);
    expect(find.byType(StaffView), findsOneWidget);
    expect(find.text('Imported from MusicXML'), findsOneWidget);

    final g = StaffLayout(score).byId['n1']!;
    await tester.tapAt(tester.getTopLeft(find.byType(StaffView)) + Offset(g.x, g.y));
    await tester.pump();
    expect(find.text('C5'), findsOneWidget);

    await tester.ensureVisible(find.byTooltip('Octave up'));
    await tester.tap(find.byTooltip('Octave up'));
    await tester.pump();
    expect(find.text('C6'), findsOneWidget);
    expect(find.text('C5'), findsNothing);

    await tester.tap(find.byTooltip('Undo'));
    await tester.pump();
    expect(find.text('C5'), findsOneWidget);

    await tester.tap(find.byTooltip('Redo'));
    await tester.pump();
    expect(find.text('C6'), findsOneWidget);

    await disposeAndFlush(tester);
    Score? saved;
    await tester.runAsync(() async => saved = await app.library.loadScore(id));
    expect(saved!.notes.firstWhere((n) => n.id == 'n1').midi, 84);
    expect(Pitch.name(84), 'C6');
  });

  testWidgets('practice with unchecked items asks first', (tester) async {
    final id = await addPiece(tester, _score(conf: 0.4));
    var opened = 0;
    await pumpScreen(tester, id, onPractice: () => opened++);
    expect(find.textContaining('1 item needs review'), findsOneWidget);

    await tester.tap(find.text('Practice'));
    await tester.pumpAndSettle();
    expect(find.textContaining('1 item hasn’t been checked yet'), findsOneWidget);
    await tester.tap(find.text('Review now'));
    await tester.pumpAndSettle();
    expect(opened, 0);
    expect(find.text('E5'), findsOneWidget, reason: 'Review now jumps to the uncertain note');

    await tester.ensureVisible(find.text('Mark as checked'));
    await tester.tap(find.text('Mark as checked'));
    await tester.pump();
    expect(find.text('Imported from MusicXML'), findsOneWidget);
    await tester.tap(find.text('Practice'));
    // Practice waits for the autosave (real file IO) before opening.
    for (var i = 0; i < 50 && opened == 0; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(opened, 1);
    await disposeAndFlush(tester);
  });

  testWidgets('missing piece shows an error', (tester) async {
    await addPiece(tester, _score());
    await pumpScreen(tester, 'does-not-exist');
    expect(find.textContaining('could not be found'), findsOneWidget);
    await disposeAndFlush(tester);
  });

  testWidgets('empty score guides manual entry and can add a note', (tester) async {
    final id = await addPiece(tester, Score(title: 'Blank', origin: ScoreOrigin.manual, measures: [
      Measure(index: 0, startTick: 0, lengthTicks: 1920, number: '1', time: const TimeSignature(4, 4), key: const KeySignature(0)),
    ]));
    await pumpScreen(tester, id);
    expect(find.textContaining('No notes yet'), findsWidgets);
    final l = StaffLayout(Score(title: 'Blank', origin: ScoreOrigin.manual, measures: [
      Measure(index: 0, startTick: 0, lengthTicks: 1920, number: '1', time: const TimeSignature(4, 4), key: const KeySignature(0)),
    ]));
    await tester.tapAt(tester.getTopLeft(find.byType(StaffView)) + Offset(l.measures[0].x + 30, 10));
    await tester.pump();
    expect(find.text('Measure 1'), findsOneWidget);
    await tester.ensureVisible(find.byTooltip('Add a right-hand note'));
    await tester.tap(find.byTooltip('Add a right-hand note'));
    await tester.pump();
    expect(find.text('C5'), findsOneWidget);
    await disposeAndFlush(tester);
  });
}
