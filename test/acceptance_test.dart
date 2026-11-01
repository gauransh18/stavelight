import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:stavelight/core/edit/score_editor.dart';
import 'package:stavelight/core/import/import_types.dart';
import 'package:stavelight/core/import/midi_parser.dart';
import 'package:stavelight/core/import/musicxml_parser.dart';
import 'package:stavelight/core/model/score.dart';
import 'package:stavelight/core/model/session.dart';
import 'package:stavelight/core/practice/input_event.dart';
import 'package:stavelight/core/practice/practice_engine.dart';
import 'package:stavelight/core/practice/timeline.dart';
import 'package:stavelight/data/library_repository.dart';

/// Minimal SMF type 0: 480 PPQ, 120 bpm, C4 D4 E4 quarters, sustain down at 0, up at beat 3.
Uint8List tinyMidi() {
  final ev = <int>[
    0x00, 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20, // tempo 500000 us
    0x00, 0xB0, 64, 127, // pedal down
    0x00, 0x90, 60, 90, 0x83, 0x60, 0x80, 60, 0, // C4 quarter
    0x00, 0x90, 62, 90, 0x83, 0x60, 0x80, 62, 0,
    0x00, 0x90, 64, 90, 0x81, 0x70, 0x80, 64, 0, // E4 eighth (held short, pedal sustains)
    0x83, 0x60, 0xB0, 64, 0, // pedal up a beat after E4 is released
    0x00, 0xFF, 0x2F, 0x00,
  ];
  return Uint8List.fromList([
    ...'MThd'.codeUnits, 0, 0, 0, 6, 0, 0, 0, 1, 0x01, 0xE0,
    ...'MTrk'.codeUnits, 0, 0, (ev.length >> 8) & 0xFF, ev.length & 0xFF, ...ev,
  ]);
}

const tiedXml = '''<?xml version="1.0"?>
<score-partwise version="3.1"><part-list><score-part id="P1"><part-name>Piano</part-name></score-part></part-list>
<part id="P1"><measure number="1"><attributes><divisions>2</divisions><time><beats>4</beats><beat-type>4</beat-type></time></attributes>
<note><pitch><step>C</step><octave>4</octave></pitch><duration>3</duration><dot/><type>quarter</type></note>
<note><pitch><step>D</step><octave>4</octave></pitch><duration>1</duration><type>eighth</type></note>
<note><pitch><step>E</step><octave>4</octave></pitch><duration>4</duration><tie type="start"/><type>half</type></note>
</measure><measure number="2">
<note><pitch><step>E</step><octave>4</octave></pitch><duration>8</duration><tie type="stop"/><type>whole</type></note>
</measure></part></score-partwise>''';

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('sl_accept'));
  tearDown(() async => dir.delete(recursive: true));

  test('MIDI import → library → restart → correct octave → wait-mode practice', () async {
    final bytes = tinyMidi();
    expect(sniffFormat(bytes, fileName: 'x.bin'), ImportFormat.midi);
    final score = parseMidi(bytes, title: 'Tiny');
    // Pedal is its own event list; note durations are the real key-hold.
    expect(score.pedals.map((p) => p.type), [PedalType.down, PedalType.up]);
    final e4 = score.notes.firstWhere((n) => n.midi == 64);
    expect(e4.effectiveHoldTicks, 240);
    expect(score.soundingEndTick(e4), greaterThan(e4.startTick + e4.effectiveHoldTicks));

    final repo = LibraryRepository(dir);
    await repo.load();
    final piece = await repo.addPiece(originals: [('tiny.mid', bytes)], format: ImportFormat.midi, score: score);

    final reopened = LibraryRepository(dir);
    await reopened.load();
    final loaded = (await reopened.loadScore(piece.id))!;
    // User fixes a wrong octave before practice; the edit is verified and saved.
    final editor = ScoreEditor(loaded);
    final d4 = loaded.notes.firstWhere((n) => n.midi == 62).id;
    editor.shiftOctave(d4, 1);
    expect(editor.score.notes.firstWhere((n) => n.id == d4).midi, 74);
    expect(editor.score.notes.firstWhere((n) => n.id == d4).verified, isTrue);
    editor.undo();
    expect(editor.score.notes.firstWhere((n) => n.id == d4).midi, 62);
    await reopened.saveScore(piece.id, editor.score);

    final engine = PracticeEngine(PracticeTimeline.build(editor.score), PracticeConfig(mode: PracticeMode.wait, countInBeats: 0), input: InputKind.midi);
    engine.start();
    engine.tick(0.05);
    expect(engine.state, EngineState.waiting);
    for (final m in [60, 62, 64]) {
      engine.handleNote(InputNoteEvent(midi: m, time: 0, on: true));
      for (var i = 0; i < 80; i++) {
        engine.tick(1 / 60);
      }
    }
    final s = engine.summarize(id: 's', pieceId: piece.id, startedAt: DateTime.now());
    expect(s.correct, 3);
    await reopened.recordSession(s, measureCount: loaded.measures.length);
    expect(reopened.byId(piece.id)!.sessions, 1);
  });

  test('MusicXML dotted and tied notes are durations, not pedal events', () {
    final s = parseMusicXml(tiedXml);
    expect(s.pedals, isEmpty);
    final c4 = s.notes.firstWhere((n) => n.midi == 60);
    expect(c4.durationTicks, 720);
    expect(c4.dots, 1);
    final e4 = s.notes.where((n) => n.midi == 64).toList()..sort((a, b) => a.startTick.compareTo(b.startTick));
    expect(e4.length, 2);
    expect(e4.first.holdTicks, 960 + 1920);
    final tl = PracticeTimeline.build(s);
    expect(tl.notes.where((n) => n.midi == 64).length, 1); // one key press for the tie chain
  });
}
