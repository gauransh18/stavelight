import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:stavelight/core/import/import_types.dart';
import 'package:stavelight/core/import/midi_parser.dart';
import 'package:stavelight/core/import/track_selection.dart';
import 'package:stavelight/core/model/pitch.dart';
import 'package:stavelight/core/model/score.dart';

/// Tiny SMF builder: events are appended with a delta time; running status is written verbatim.
class TrackBuilder {
  final bytes = <int>[];

  void delta(int d) {
    final out = <int>[d & 0x7F];
    d >>= 7;
    while (d > 0) {
      out.insert(0, 0x80 | (d & 0x7F));
      d >>= 7;
    }
    bytes.addAll(out);
  }

  void raw(int d, List<int> data) {
    delta(d);
    bytes.addAll(data);
  }

  void on(int d, int key, {int ch = 0, int vel = 100}) => raw(d, [0x90 | ch, key, vel]);
  void off(int d, int key, {int ch = 0}) => raw(d, [0x80 | ch, key, 0]);
  void cc(int d, int ctrl, int value, {int ch = 0}) => raw(d, [0xB0 | ch, ctrl, value]);
  void meta(int d, int type, List<int> data) => raw(d, [0xFF, type, data.length, ...data]);
  void tempo(int d, double bpm) {
    final us = (60000000 / bpm).round();
    meta(d, 0x51, [us >> 16 & 0xFF, us >> 8 & 0xFF, us & 0xFF]);
  }

  void timeSig(int d, int beats, int beatTypePow) => meta(d, 0x58, [beats, beatTypePow, 24, 8]);
  void name(String n) => meta(0, 0x03, n.codeUnits);
  void end([int d = 0]) => meta(d, 0x2F, []);

  List<int> chunk() => [..._ascii('MTrk'), ..._u32(bytes.length), ...bytes];
}

List<int> _ascii(String s) => s.codeUnits;
List<int> _u32(int v) => [v >> 24 & 0xFF, v >> 16 & 0xFF, v >> 8 & 0xFF, v & 0xFF];
List<int> _u16(int v) => [v >> 8 & 0xFF, v & 0xFF];

Uint8List smf(int format, int ppq, List<TrackBuilder> tracks) => Uint8List.fromList([
      ..._ascii('MThd'),
      ..._u32(6),
      ..._u16(format),
      ..._u16(tracks.length),
      ..._u16(ppq),
      for (final t in tracks) ...t.chunk(),
    ]);

void main() {
  test('format 0 with running status, program change and note-on velocity 0', () {
    final t = TrackBuilder()
      ..raw(0, [0xC0, 0]) // program change: 1 data byte
      ..raw(0, [0x90, 60, 90]) // C4 on
      ..raw(480, [62, 80]) // running status: D4 on
      ..raw(0, [60, 0]) // running status: C4 off via velocity 0
      ..raw(480, [62, 0]) // D4 off
      ..end();
    final s = parseMidi(smf(0, 480, [t]), title: 'Test');

    expect(s.origin, ScoreOrigin.midi);
    expect(s.review, ReviewState.parsed);
    expect(s.notes.map((n) => n.midi), [60, 62]);
    expect(s.notes[0].startTick, 0);
    expect(s.notes[0].durationTicks, 480);
    expect(s.notes[0].holdTicks, 480);
    expect(s.notes[1].startTick, 480);
    expect(s.notes[1].velocity, 80);
    expect(s.notes.every((n) => n.confidence == 1.0 && !n.verified), isTrue);
    expect(s.tempos.single.bpm, 120);
    expect(s.measures, hasLength(1));
    expect(s.tracks, hasLength(1));
    expect(s.pedalDataPresent, isFalse);
  });

  test('format 0 splits channels into tracks', () {
    final t = TrackBuilder()
      ..name('Piano')
      ..on(0, 72)
      ..on(0, 48, ch: 1)
      ..off(480, 72)
      ..off(0, 48, ch: 1)
      ..on(0, 50, ch: 2)
      ..off(480, 50, ch: 2)
      ..end();
    final s = parseMidi(smf(0, 480, [t]), title: 'x');
    expect(s.tracks.map((t) => t.name), ['Piano (ch 1)', 'Piano (ch 2)', 'Piano (ch 3)']);
    expect(s.tracks.every((t) => t.hand == Hand.unassigned), isTrue);
    final c4 = s.notes.firstWhere((n) => n.midi == 72);
    final c3 = s.notes.firstWhere((n) => n.midi == 48);
    expect(c4.staff, 1);
    expect(c3.staff, 2);
    expect(c3.track, 1);
  });

  test('format 1: tempo change mid-piece and TempoMap seconds', () {
    final conductor = TrackBuilder()
      ..tempo(0, 120)
      ..tempo(1920, 60) // after one 4/4 bar
      ..end();
    final piano = TrackBuilder()
      ..on(0, 60)
      ..off(3840, 60)
      ..end();
    final s = parseMidi(smf(1, 480, [conductor, piano]), title: 'x');
    expect(s.tempos.map((t) => (t.tick, t.bpm)), [(0, 120.0), (1920, 60.0)]);
    final map = s.tempoMap;
    expect(map.secondsAt(1920), closeTo(2.0, 1e-9));
    expect(map.secondsAt(3840), closeTo(6.0, 1e-9));
    expect(s.tracks, hasLength(1)); // conductor track has no notes
    expect(s.notes.single.track, 0);
  });

  test('3/4 time signature builds 3/4 measures covering the piece', () {
    final t = TrackBuilder()
      ..timeSig(0, 3, 2)
      ..on(0, 60)
      ..off(1440 * 3 - 10, 60)
      ..end();
    final s = parseMidi(smf(0, 480, [t]), title: 'x');
    expect(s.measures, hasLength(3));
    expect(s.measures.every((m) => m.time == const TimeSignature(3, 4) && m.lengthTicks == 1440), isTrue);
    expect(s.measures.map((m) => m.number), ['1', '2', '3']);
    expect(s.measures[2].startTick, 2880);
  });

  test('time signature change cuts measures at the change point', () {
    final t = TrackBuilder()
      ..timeSig(0, 4, 2)
      ..on(0, 60)
      ..timeSig(1920, 6, 3)
      ..off(1440, 60)
      ..end();
    final s = parseMidi(smf(0, 480, [t]), title: 'x');
    expect(s.measures.map((m) => m.time.label), ['4/4', '6/8']);
    expect(s.measures[1].startTick, 1920);
    expect(s.measures[1].lengthTicks, 1440);
  });

  test('CC64 becomes pedal events and never extends a note (acceptance)', () {
    final t = TrackBuilder()
      ..cc(0, 64, 0) // leading "up" is a no-op
      ..cc(0, 64, 127)
      ..on(0, 60)
      ..cc(100, 64, 100) // still down: deduplicated
      ..off(140, 60) // released after 240 ticks while pedal is down
      ..cc(720, 64, 0) // pedal up at 960
      ..cc(10, 64, 20) // still up: deduplicated
      ..end();
    final s = parseMidi(smf(0, 480, [t]), title: 'x');

    expect(s.pedalDataPresent, isTrue);
    expect(s.pedals.map((p) => (p.tick, p.type)), [(0, PedalType.down), (960, PedalType.up)]);
    expect(s.pedals.every((p) => p.source == 'midi' && p.verified && p.confidence == 1.0), isTrue);

    final n = s.notes.single;
    expect(n.holdTicks, 240);
    expect(n.durationTicks, 240);
    expect(s.soundingEndTick(n), 960); // pedal extends sound only, derived at display time
  });

  test('PPQ 96 is rescaled to 480', () {
    final t = TrackBuilder()
      ..on(96, 64)
      ..off(48, 64)
      ..cc(0, 64, 127)
      ..end();
    final s = parseMidi(smf(0, 96, [t]), title: 'x');
    expect(s.notes.single.startTick, 480);
    expect(s.notes.single.durationTicks, 240);
    expect(s.pedals.single.tick, 720);
  });

  test('drum channel is dropped and reported', () {
    final t = TrackBuilder()
      ..on(0, 36, ch: 9)
      ..on(0, 60)
      ..off(480, 36, ch: 9)
      ..off(0, 60)
      ..end();
    final s = parseMidi(smf(0, 480, [t]), title: 'x');
    expect(s.notes.single.midi, 60);
    expect(s.issues.any((i) => i.message.contains('drum')), isTrue);
  });

  test('drums only throws a friendly error', () {
    final t = TrackBuilder()
      ..on(0, 36, ch: 9)
      ..off(480, 36, ch: 9)
      ..end();
    expect(() => parseMidi(smf(0, 480, [t]), title: 'x'), throwsA(isA<ImportException>()));
  });

  test('two note tracks become right and left hands', () {
    final rh = TrackBuilder()
      ..name('Right')
      ..on(0, 50) // low note on the right-hand track still goes to the right hand
      ..off(480, 50)
      ..end();
    final lh = TrackBuilder()
      ..name('Left')
      ..on(0, 70)
      ..off(480, 70)
      ..end();
    final s = parseMidi(smf(1, 480, [TrackBuilder()..end(), rh, lh]), title: 'x');
    expect(s.tracks.map((t) => (t.name, t.hand, t.index)), [('Right', Hand.right, 0), ('Left', Hand.left, 1)]);
    final r = s.notes.firstWhere((n) => n.midi == 50);
    final l = s.notes.firstWhere((n) => n.midi == 70);
    expect((r.hand, r.staff, r.track), (Hand.right, 1, 0));
    expect((l.hand, l.staff, l.track), (Hand.left, 2, 1));
    expect(s.tracks[0].lowest, 50);
  });

  test('overlapping same-key notes match FIFO; dangling notes closed at end of track', () {
    final t = TrackBuilder()
      ..on(0, 60)
      ..on(100, 60)
      ..off(100, 60) // closes the first (FIFO): length 200
      ..off(100, 60) // closes the second: length 200
      ..on(0, 64) // never released
      ..end(480);
    final s = parseMidi(smf(0, 480, [t]), title: 'x');
    final c = s.notes.where((n) => n.midi == 60).toList();
    expect(c.map((n) => (n.startTick, n.holdTicks)), [(0, 200), (100, 200)]);
    expect(s.notes.firstWhere((n) => n.midi == 64).holdTicks, 480);
    expect(s.issues.any((i) => i.message.contains('no note-off')), isTrue);
  });

  test('key signature, sysex skip and RIFF RMID wrapper', () {
    final t = TrackBuilder()
      ..meta(0, 0x59, [0xFD, 1]) // 3 flats, minor
      ..raw(0, [0xF0, 3, 1, 2, 0xF7])
      ..on(0, 63)
      ..off(480, 63)
      ..end();
    final midi = smf(0, 480, [t]);
    final dataChunk = [..._ascii('data'), midi.length & 0xFF, midi.length >> 8 & 0xFF, 0, 0, ...midi];
    if (midi.length.isOdd) dataChunk.add(0);
    final riffBody = [..._ascii('RMID'), ...dataChunk];
    final rmid = Uint8List.fromList([
      ..._ascii('RIFF'),
      riffBody.length & 0xFF,
      riffBody.length >> 8 & 0xFF,
      0,
      0,
      ...riffBody,
    ]);
    final s = parseMidi(rmid, title: 'x');
    expect(s.measures.first.key, const KeySignature(-3, minor: true));
    expect(s.notes.single.midi, 63);
  });

  test('same-tick pedal up/down pairs keep their order beyond small lists', () {
    final t = TrackBuilder()
      ..cc(0, 64, 127)
      ..on(0, 60);
    for (var i = 0; i < 40; i++) {
      t
        ..cc(480, 64, 0)
        ..cc(0, 64, 127);
    }
    t
      ..off(0, 60)
      ..end();
    final s = parseMidi(smf(0, 480, [t]), title: 'x');
    expect(s.pedals, hasLength(81));
    final selected = applyTrackSelection(s, s.tracks);
    for (var i = 0; i <= 40; i++) {
      expect(s.pedalDownAt(i * 480), isTrue, reason: 'tick ${i * 480}');
      expect(selected.pedalDownAt(i * 480), isTrue, reason: 'selection, tick ${i * 480}');
    }
  });

  test('SMPTE division and garbage are rejected with ImportException', () {
    final t = TrackBuilder()
      ..on(0, 60)
      ..off(10, 60)
      ..end();
    final bytes = smf(0, 480, [t]);
    bytes[12] = 0xE7; // -25 fps
    bytes[13] = 40;
    expect(
      () => parseMidi(bytes, title: 'x'),
      throwsA(isA<ImportException>().having((e) => e.message, 'message', contains('SMPTE'))),
    );
    expect(() => parseMidi(Uint8List.fromList([1, 2, 3]), title: 'x'), throwsA(isA<ImportException>()));
  });
}
