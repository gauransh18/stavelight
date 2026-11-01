import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stavelight/core/import/import_types.dart';
import 'package:stavelight/core/import/musicxml_parser.dart';
import 'package:stavelight/core/model/pitch.dart';
import 'package:stavelight/core/model/score.dart';

/// Wraps measures of a single piano part in a minimal score-partwise document.
String doc(String measures, {String head = '', String partName = 'Piano'}) => '''<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<!DOCTYPE score-partwise PUBLIC "-//Recordare//DTD MusicXML 4.0 Partwise//EN" "http://www.musicxml.org/dtds/partwise.dtd">
<score-partwise version="4.0">
  $head
  <part-list><score-part id="P1"><part-name>$partName</part-name></score-part></part-list>
  <part id="P1">$measures</part>
</score-partwise>''';

String attrs({int divisions = 1, int beats = 4, int beatType = 4, int fifths = 0, String mode = 'major', int staves = 1}) =>
    '<attributes><divisions>$divisions</divisions><key><fifths>$fifths</fifths><mode>$mode</mode></key>'
    '<time><beats>$beats</beats><beat-type>$beatType</beat-type></time><staves>$staves</staves>'
    '<clef><sign>G</sign><line>2</line></clef></attributes>';

String note(String step, int octave, int dur,
        {int alter = 0, String extra = '', String inner = '', int voice = 1, int staff = 1}) =>
    '<note>$inner<pitch><step>$step</step>${alter != 0 ? '<alter>$alter</alter>' : ''}<octave>$octave</octave></pitch>'
    '<duration>$dur</duration><voice>$voice</voice>$extra<staff>$staff</staff></note>';

String rest(int dur) => '<note><rest/><duration>$dur</duration><voice>1</voice></note>';

void main() {
  test('title, composer, divisions rescale and dotted quarter (no pedal)', () {
    final s = parseMusicXml(doc(
      '<measure number="1">${attrs(divisions: 2)}'
      '${note('C', 4, 3, extra: '<type>quarter</type><dot/>')}${note('D', 4, 1)}${note('E', 4, 4)}</measure>',
      head: '<work><work-title>Study</work-title></work>'
          '<identification><creator type="composer">Anon</creator></identification>',
    ));
    expect(s.title, 'Study');
    expect(s.composer, 'Anon');
    expect(s.origin, ScoreOrigin.musicxml);
    expect(s.review, ReviewState.parsed);
    final dotted = s.notes[0];
    expect((dotted.midi, dotted.durationTicks, dotted.holdTicks, dotted.dots), (60, 720, 720, 1));
    expect(s.notes[1].startTick, 720);
    expect(s.notes[1].durationTicks, 240);
    expect(s.notes[2].startTick, 960);
    expect(s.pedals, isEmpty);
    expect(s.pedalDataPresent, isFalse);
    expect(s.tempos.single.bpm, 100);
    expect(s.tracks.single.name, 'Piano');
  });

  test('fallback title when the file has none', () {
    final s = parseMusicXml(doc('<measure number="1">${attrs()}${note('C', 4, 4)}</measure>'), fallbackTitle: 'File');
    expect(s.title, 'File');
  });

  test('tie chain keeps separate noteheads; first carries the summed hold', () {
    final s = parseMusicXml(doc(
      '<measure number="1">${attrs()}${note('G', 4, 4, extra: '<tie type="start"/>')}</measure>'
      '<measure number="2">${note('G', 4, 2, extra: '<tie type="stop"/><tie type="start"/>')}'
      '${note('G', 4, 2, extra: '<tie type="stop"/>')}</measure>',
    ));
    expect(s.notes, hasLength(3));
    final [a, b, c] = s.notes;
    expect((a.durationTicks, a.holdTicks, a.tieStart, a.tieStop), (1920, 3840, true, false));
    expect((b.durationTicks, b.holdTicks, b.tieStart, b.tieStop), (960, null, true, true));
    expect((c.durationTicks, c.holdTicks, c.tieStart, c.tieStop), (960, null, false, true));
    expect(c.startTick, 2880);
    expect(c.measureIndex, 1);
  });

  test('chord notes share the onset and advance the cursor once', () {
    final s = parseMusicXml(doc(
      '<measure number="1">${attrs()}${note('C', 4, 1)}${note('E', 4, 1, inner: '<chord/>')}'
      '${note('G', 4, 1, inner: '<chord/>')}${note('A', 4, 3)}</measure>',
    ));
    expect(s.notes.map((n) => (n.midi, n.startTick)), [(60, 0), (64, 0), (67, 0), (69, 480)]);
  });

  test('backup with two staves and voices assigns hands', () {
    final s = parseMusicXml(doc(
      '<measure number="1">${attrs(staves: 2)}${note('C', 5, 2)}${note('D', 5, 2)}'
      '<backup><duration>4</duration></backup>${note('C', 3, 4, voice: 5, staff: 2)}</measure>',
    ));
    final low = s.notes.firstWhere((n) => n.midi == 48);
    final high = s.notes.firstWhere((n) => n.midi == 72);
    expect((low.startTick, low.staff, low.voice, low.hand), (0, 2, 5, Hand.left));
    expect((high.startTick, high.staff, high.voice, high.hand), (0, 1, 1, Hand.right));
    expect(s.notes.firstWhere((n) => n.midi == 74).startTick, 960);
    expect(s.measures.single.lengthTicks, 1920);
  });

  test('single-staff part is unassigned on staff 1', () {
    final s = parseMusicXml(doc('<measure number="1">${attrs()}${note('C', 3, 4)}</measure>'));
    expect((s.notes.single.hand, s.notes.single.staff), (Hand.unassigned, 1));
  });

  test('pedal markings are separate events and never change notes', () {
    const pedalStart = '<direction><direction-type><pedal type="start" line="yes"/></direction-type>'
        '<sound damper-pedal="yes"/></direction>';
    const pedalChange = '<direction><direction-type><pedal type="change"/></direction-type></direction>';
    const pedalStop = '<direction><direction-type><pedal type="stop"/></direction-type><offset>1</offset></direction>';
    final s = parseMusicXml(doc(
      '<measure number="1">${attrs()}$pedalStart${note('C', 4, 1)}${note('E', 4, 1)}'
      '$pedalChange${note('G', 4, 1)}$pedalStop${note('C', 5, 1)}</measure>',
    ));
    expect(s.pedalDataPresent, isTrue);
    expect(s.pedals.every((p) => p.source == 'musicxml' && p.verified && p.confidence == 1.0), isTrue);
    // start (pedal + sound counted once), change (up+down at 960), stop at 1440 + 480 offset.
    expect(s.pedals, hasLength(4));
    expect((s.pedals.first.tick, s.pedals.first.type), (0, PedalType.down));
    expect(s.pedals.where((p) => p.tick == 960).map((p) => p.type).toSet(), {PedalType.up, PedalType.down});
    expect((s.pedals.last.tick, s.pedals.last.type), (1920, PedalType.up));
    expect(s.notes.every((n) => n.durationTicks == 480 && n.holdTicks == 480), isTrue);
  });

  test('pedal "change" stays up-then-down in long pieces', () {
    const change = '<direction><direction-type><pedal type="change"/></direction-type></direction>';
    final measures = StringBuffer('<measure number="1">${attrs()}'
        '<direction><direction-type><pedal type="start"/></direction-type></direction>${note('C', 4, 4)}</measure>');
    for (var i = 2; i <= 41; i++) {
      measures.write('<measure number="$i">$change${note('C', 4, 4)}</measure>');
    }
    final s = parseMusicXml(doc(measures.toString()));
    expect(s.pedals, hasLength(81));
    for (var i = 0; i <= 40; i++) {
      expect(s.pedalDownAt(i * 1920), isTrue, reason: 'tick ${i * 1920}');
    }
  });

  test('sound damper-pedal without a pedal mark', () {
    final s = parseMusicXml(doc(
      '<measure number="1">${attrs()}<sound damper-pedal="100"/>${note('C', 4, 2)}'
      '<direction><direction-type><words>x</words></direction-type><sound damper-pedal="no"/></direction>'
      '${note('C', 4, 2)}</measure>',
    ));
    expect(s.pedals.map((p) => (p.tick, p.type)), [(0, PedalType.down), (960, PedalType.up)]);
  });

  test('sound tempo wins over metronome; metronome used as fallback', () {
    const met = '<direction><direction-type><metronome><beat-unit>quarter</beat-unit><beat-unit-dot/>'
        '<per-minute>60</per-minute></metronome></direction-type></direction>';
    final withSound = parseMusicXml(doc(
      '<measure number="1">${attrs()}$met<direction><direction-type><words>Andante</words></direction-type>'
      '<sound tempo="72"/></direction>${note('C', 4, 4)}</measure>'
      '<measure number="2"><sound tempo="90"/>${note('C', 4, 4)}</measure>',
    ));
    expect(withSound.tempos.map((t) => (t.tick, t.bpm)), [(0, 72.0), (1920, 90.0)]);
    expect(withSound.tempoMap.secondsAt(1920), closeTo(4 * 60 / 72, 1e-9));

    final metOnly = parseMusicXml(doc('<measure number="1">${attrs()}$met${note('C', 4, 4)}</measure>'));
    expect(metOnly.tempos.single.bpm, 90); // dotted quarter = 60
  });

  test('implicit pickup measure', () {
    final s = parseMusicXml(doc(
      '<measure number="0" implicit="yes">${attrs(beats: 3)}${note('G', 4, 1)}</measure>'
      '<measure number="1">${note('C', 5, 3)}</measure>'
      '<measure number="2">${note('C', 5, 3)}</measure>',
    ));
    expect(s.measures.map((m) => (m.number, m.startTick, m.lengthTicks, m.pickup)),
        [('0', 0, 480, true), ('1', 480, 1440, false), ('2', 1920, 1440, false)]);
    expect(s.notes[1].measureIndex, 1);
  });

  test('short first measure without implicit is still a pickup', () {
    final s = parseMusicXml(doc(
      '<measure number="1">${attrs()}${note('G', 4, 1)}</measure><measure number="2">${note('C', 5, 4)}</measure>',
    ));
    expect(s.measures.first.pickup, isTrue);
    expect(s.measures[1].startTick, 480);
  });

  test('key, time, rest, fingering and explicit accidental', () {
    final s = parseMusicXml(doc(
      '<measure number="1">${attrs(beats: 6, beatType: 8, fifths: -2, mode: 'minor', divisions: 2)}'
      '${rest(2)}'
      '${note('F', 4, 2, alter: 1, extra: '<accidental>sharp</accidental>', inner: '')}'
      '${note('E', 4, 2, alter: -1, extra: '<notations><technical><fingering>3</fingering></technical></notations>')}'
      '</measure>',
    ));
    final m = s.measures.single;
    expect(m.time, const TimeSignature(6, 8));
    expect(m.key, const KeySignature(-2, minor: true));
    expect(m.lengthTicks, 1440);
    expect(s.rests.single.startTick, 0);
    expect(s.rests.single.durationTicks, 480);
    final fs = s.notes[0], eb = s.notes[1];
    expect((fs.midi, fs.accidental, fs.startTick), (66, 1, 480));
    expect((eb.midi, eb.accidental, eb.finger), (63, null, 3));
  });

  test('grace and cue notes skipped; repeats reported', () {
    final s = parseMusicXml(doc(
      '<measure number="1">${attrs()}${note('D', 4, 0, inner: '<grace/>')}${note('C', 4, 2)}'
      '${note('E', 4, 2, inner: '<cue/>')}<barline location="right"><repeat direction="backward"/></barline></measure>'
      '<measure number="2">${note('F', 4, 4)}</measure>',
    ));
    expect(s.notes.map((n) => (n.midi, n.startTick)), [(60, 0), (65, 1920)]);
    expect(s.issues.any((i) => i.message.contains('Grace')), isTrue);
    expect(s.issues.any((i) => i.message.contains('Repeats')), isTrue);
  });

  test('two parts become two tracks', () {
    const xml = '''<score-partwise><part-list>
      <score-part id="A"><part-name>Melody</part-name></score-part>
      <score-part id="B"><part-name>Bass</part-name></score-part></part-list>
      <part id="A"><measure number="1"><attributes><divisions>1</divisions></attributes>
        <note><pitch><step>E</step><octave>5</octave></pitch><duration>4</duration></note></measure></part>
      <part id="B"><measure number="1"><attributes><divisions>4</divisions></attributes>
        <note><pitch><step>C</step><octave>3</octave></pitch><duration>16</duration></note></measure></part>
    </score-partwise>''';
    final s = parseMusicXml(xml);
    expect(s.tracks.map((t) => (t.index, t.name, t.noteCount)), [(0, 'Melody', 1), (1, 'Bass', 1)]);
    expect(s.notes.map((n) => (n.midi, n.track, n.durationTicks)), [(48, 1, 1920), (76, 0, 1920)]);
  });

  test('malformed, timewise and non-score XML throw ImportException', () {
    expect(() => parseMusicXml('<score-partwise><part>'), throwsA(isA<ImportException>()));
    expect(
      () => parseMusicXml('<score-timewise/>'),
      throwsA(isA<ImportException>().having((e) => e.message, 'message', contains('partwise'))),
    );
    expect(() => parseMusicXml('<html/>'), throwsA(isA<ImportException>()));
  });

  test('.mxl round trip via container.xml and fallback', () {
    final xml = doc('<measure number="1">${attrs()}${note('A', 4, 4)}</measure>');
    const container = '<?xml version="1.0"?><container><rootfiles>'
        '<rootfile full-path="score/piece.musicxml" media-type="application/vnd.recordare.musicxml+xml"/>'
        '</rootfiles></container>';
    final zip = Archive()
      ..addFile(ArchiveFile.string('META-INF/container.xml', container))
      ..addFile(ArchiveFile.string('other.xml', '<not-a-score/>'))
      ..addFile(ArchiveFile.bytes('score/piece.musicxml', utf8.encode(xml)));
    final s = parseMxl(Uint8List.fromList(ZipEncoder().encode(zip)), fallbackTitle: 'Zipped');
    expect(s.notes.single.midi, 69);
    expect(s.title, 'Zipped');

    final bare = Archive()..addFile(ArchiveFile.bytes('piece.xml', utf8.encode(xml)));
    expect(parseMxl(Uint8List.fromList(ZipEncoder().encode(bare))).notes.single.midi, 69);

    expect(() => parseMxl(Uint8List.fromList([1, 2, 3, 4])), throwsA(isA<ImportException>()));
  });
}
