import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import '../model/pitch.dart';
import '../model/score.dart';
import '../util/ids.dart';
import 'import_types.dart';

const _unreadable = 'This MusicXML file couldn\'t be read. It may be damaged or not a MusicXML score.';

/// Parses a compressed MusicXML (.mxl) archive. Uses META-INF/container.xml's rootfile, else the first score file.
Score parseMxl(Uint8List zipBytes, {String? fallbackTitle}) {
  final Archive zip;
  try {
    zip = ZipDecoder().decodeBytes(zipBytes);
  } catch (e) {
    throw ImportException('This .mxl file couldn\'t be opened. It may be damaged.', '$e');
  }
  ArchiveFile? find(String name) {
    for (final f in zip.files) {
      if (f.isFile && f.name == name) return f;
    }
    return null;
  }

  ArchiveFile? root;
  final container = find('META-INF/container.xml');
  if (container != null) {
    try {
      final doc = XmlDocument.parse(_decodeText(container.content));
      final path = doc.findAllElements('rootfile').map((e) => e.getAttribute('full-path')).nonNulls.firstOrNull;
      if (path != null) root = find(path);
    } on Exception {
      // Fall through to the first score file.
    }
  }
  root ??= zip.files
      .where((f) => f.isFile && !f.name.startsWith('META-INF/'))
      .where((f) => f.name.toLowerCase().endsWith('.xml') || f.name.toLowerCase().endsWith('.musicxml'))
      .firstOrNull;
  if (root == null) throw ImportException('No MusicXML score was found inside this .mxl file.');
  return parseMusicXml(_decodeText(root.content), fallbackTitle: fallbackTitle);
}

String _decodeText(Uint8List b) {
  final le = b.length >= 2 && b[0] == 0xFF && b[1] == 0xFE;
  final be = b.length >= 2 && b[0] == 0xFE && b[1] == 0xFF;
  if (le || be) {
    final units = <int>[];
    for (var i = 2; i + 1 < b.length; i += 2) {
      units.add(le ? b[i] | b[i + 1] << 8 : b[i] << 8 | b[i + 1]);
    }
    return String.fromCharCodes(units);
  }
  return utf8.decode(b, allowMalformed: true);
}

/// Parses an uncompressed score-partwise MusicXML document into a [Score].
///
/// Tied noteheads stay separate; the first note of a tie chain carries the chain's total [ScoreNote.holdTicks].
/// Pedal markings become [PedalEvent]s and never change note durations. Repeats are not unrolled.
Score parseMusicXml(String xmlText, {String? fallbackTitle}) {
  final XmlDocument doc;
  try {
    doc = XmlDocument.parse(xmlText.startsWith('﻿') ? xmlText.substring(1) : xmlText);
  } on XmlException catch (e) {
    throw ImportException(_unreadable, '$e');
  } on FormatException catch (e) {
    throw ImportException(_unreadable, '$e');
  }
  final root = doc.rootElement;
  if (root.name.local == 'score-timewise') {
    throw ImportException(
      'This MusicXML file is "timewise", which isn\'t supported. Re-export it as standard (partwise) MusicXML.',
    );
  }
  if (root.name.local != 'score-partwise') throw ImportException(_unreadable, 'root <${root.name.local}>');

  String? text(XmlElement? e) {
    final t = e?.innerText.trim();
    return (t == null || t.isEmpty) ? null : t;
  }

  final title = text(root.getElement('work')?.getElement('work-title')) ??
      text(root.getElement('movement-title')) ??
      fallbackTitle ??
      'Untitled';
  final composer = text(root
      .getElement('identification')
      ?.findElements('creator')
      .where((e) => e.getAttribute('type') == 'composer')
      .firstOrNull);
  final partNames = <String, String>{
    for (final sp in root.getElement('part-list')?.findElements('score-part') ?? const <XmlElement>[])
      sp.getAttribute('id') ?? '': text(sp.getElement('part-name')) ?? '',
  };

  final parts = root.findElements('part').toList();
  if (parts.isEmpty) throw ImportException('This MusicXML file has no parts.');

  final p = _Parser();
  for (var i = 0; i < parts.length; i++) {
    final notesBefore = p.notes.length;
    p.parsePart(parts[i], i);
    final partNotes = p.notes.sublist(notesBefore);
    if (partNotes.isEmpty) continue;
    var lo = 127, hi = 0;
    for (final n in partNotes) {
      if (n.midi < lo) lo = n.midi;
      if (n.midi > hi) hi = n.midi;
    }
    final id = parts[i].getAttribute('id') ?? '';
    final name = partNames[id];
    p.tracks.add(TrackInfo(
      index: i,
      name: (name == null || name.isEmpty) ? 'Part ${i + 1}' : name,
      noteCount: partNotes.length,
      lowest: lo,
      highest: hi,
    ));
  }
  if (p.notes.isEmpty && p.rests.isEmpty) throw ImportException('This MusicXML file has no notes.');

  final tempoSource = p.soundTempos.isNotEmpty ? p.soundTempos : p.metronomeTempos;
  final tempoByTick = <int, double>{for (final t in tempoSource) t.tick: t.bpm};
  final tempos = [for (final t in tempoByTick.keys.toList()..sort()) TempoEvent(t, tempoByTick[t]!)];
  if (tempos.isEmpty || tempos.first.tick > 0) tempos.insert(0, TempoEvent(0, tempos.isEmpty ? 100 : tempos.first.bpm));

  final pedals = [for (var i = 0; i < p.pedals.length; i++) (p.pedals[i], i)]
    ..sort((a, b) => a.$1.tick != b.$1.tick ? a.$1.tick.compareTo(b.$1.tick) : a.$2.compareTo(b.$2));
  final ordered = [for (final e in pedals) e.$1];
  final score = Score(
    title: title,
    composer: composer,
    origin: ScoreOrigin.musicxml,
    review: ReviewState.parsed,
    notes: p.notes,
    rests: p.rests,
    pedals: [...ordered],
    tempos: tempos,
    measures: p.measures,
    tracks: p.tracks,
    issues: p.issues,
    pedalDataPresent: ordered.isNotEmpty,
  )..normalize();
  // normalize()'s sort is unstable; restore the stable order so a pedal "change" stays up-then-down.
  return score..pedals = ordered;
}

class _Chain {
  final ScoreNote first;
  int total;
  _Chain(this.first, this.total);
}

class _Parser {
  final notes = <ScoreNote>[];
  final rests = <ScoreRest>[];
  final pedals = <PedalEvent>[];
  final soundTempos = <TempoEvent>[];
  final metronomeTempos = <TempoEvent>[];
  final measures = <Measure>[];
  final tracks = <TrackInfo>[];
  final issues = <ScoreIssue>[];
  var _graceReported = false;
  var _repeatReported = false;

  static int? _int(XmlElement? e) => e == null ? null : int.tryParse(e.innerText.trim());
  static double? _num(String? s) => s == null ? null : double.tryParse(s.trim());

  void parsePart(XmlElement part, int partIndex) {
    var divisions = 1.0;
    var staves = 1;
    var time = const TimeSignature(4, 4);
    var key = const KeySignature(0);
    var timeKnown = false;
    final chains = <String, _Chain>{};
    var mIndex = 0;

    int ticks(num div) => (div * kPpq / divisions).round();

    for (final m in part.findElements('measure')) {
      final start = mIndex < measures.length ? measures[mIndex].startTick : (measures.isEmpty ? 0 : measures.last.endTick);
      var pos = 0, maxPos = 0, onset = 0;

      void addPedal(int tick, PedalType type) => pedals.add(PedalEvent(
            id: newId('p'),
            tick: tick,
            type: type,
            confidence: 1.0,
            verified: true,
            source: 'musicxml',
          ));

      void sound(XmlElement s, int tick, {required bool pedalMarked}) {
        final bpm = _num(s.getAttribute('tempo'));
        if (bpm != null && bpm > 0) soundTempos.add(TempoEvent(tick, bpm));
        final damper = s.getAttribute('damper-pedal')?.trim();
        if (damper != null && !pedalMarked) {
          final v = damper == 'yes' ? 100.0 : (damper == 'no' ? 0.0 : _num(damper));
          if (v != null) addPedal(tick, v >= 50 ? PedalType.down : PedalType.up);
        }
      }

      for (final c in m.childElements) {
        switch (c.name.local) {
          case 'attributes':
            final d = _num(c.getElement('divisions')?.innerText);
            if (d != null && d > 0) divisions = d;
            final st = _int(c.getElement('staves'));
            if (st != null && st > 0) staves = st;
            final k = c.getElement('key');
            final fifths = _int(k?.getElement('fifths'));
            if (fifths != null) {
              key = KeySignature(fifths.clamp(-7, 7), minor: text(k?.getElement('mode')) == 'minor');
            }
            final t = c.getElement('time');
            final beats = _int(t?.getElement('beats')), beatType = _int(t?.getElement('beat-type'));
            if (beats != null && beatType != null && beats > 0 && beatType > 0) {
              time = TimeSignature(beats, beatType);
              timeKnown = true;
            }
          case 'backup':
            pos = (pos - ticks(_num(c.getElement('duration')?.innerText) ?? 0)).clamp(0, 1 << 40);
          case 'forward':
            pos += ticks(_num(c.getElement('duration')?.innerText) ?? 0);
            if (pos > maxPos) maxPos = pos;
          case 'direction':
            final offset = ticks(_num(c.getElement('offset')?.innerText) ?? 0);
            final tick = start + pos + offset;
            var pedalMarked = false;
            double? metronome;
            for (final dt in c.findElements('direction-type')) {
              for (final pe in dt.findElements('pedal')) {
                final type = pe.getAttribute('type');
                if (type == 'sostenuto') continue;
                pedalMarked = true;
                switch (type) {
                  case 'start' || 'resume':
                    addPedal(tick, PedalType.down);
                  case 'stop' || 'discontinue':
                    addPedal(tick, PedalType.up);
                  case 'change':
                    addPedal(tick, PedalType.up);
                    addPedal(tick, PedalType.down);
                }
              }
              final met = dt.getElement('metronome');
              final perMinute = _num(met?.getElement('per-minute')?.innerText);
              if (met != null && perMinute != null && perMinute > 0) {
                metronome = perMinute * _unitQuarters(text(met.getElement('beat-unit')), met.findElements('beat-unit-dot').length);
              }
            }
            if (metronome != null) metronomeTempos.add(TempoEvent(tick, metronome));
            final s = c.getElement('sound');
            if (s != null) sound(s, tick, pedalMarked: pedalMarked);
          case 'sound':
            sound(c, start + pos, pedalMarked: false);
          case 'barline':
            if (c.getElement('repeat') != null && !_repeatReported) {
              _repeatReported = true;
              issues.add(ScoreIssue('Repeats are shown once; practice plays straight through.', severity: 'info'));
            }
          case 'note':
            if (c.getElement('grace') != null) {
              if (!_graceReported) {
                _graceReported = true;
                issues.add(ScoreIssue('Grace notes were left out.', severity: 'info'));
              }
              continue;
            }
            final dur = ticks(_num(c.getElement('duration')?.innerText) ?? 0);
            final isChord = c.getElement('chord') != null;
            final noteStart = isChord ? onset : pos;
            if (!isChord) {
              onset = pos;
              pos += dur;
              if (pos > maxPos) maxPos = pos;
            }
            if (c.getElement('cue') != null || c.getElement('unpitched') != null) continue;
            final staff = (_int(c.getElement('staff')) ?? 1).clamp(1, 2);
            final voice = _int(c.getElement('voice')) ?? 1;
            final dots = c.findElements('dot').length;
            if (c.getElement('rest') != null) {
              rests.add(ScoreRest(startTick: start + noteStart, durationTicks: dur, staff: staff, voice: voice));
              continue;
            }
            final pitch = c.getElement('pitch');
            if (pitch == null) continue;
            final step = Pitch.stepLetters.indexOf(text(pitch.getElement('step'))?.toUpperCase() ?? '');
            final octave = _int(pitch.getElement('octave'));
            if (step < 0 || octave == null) continue;
            final alter = (_num(pitch.getElement('alter')?.innerText) ?? 0).round().clamp(-2, 2);
            final midi = Pitch.fromStep(step, alter, octave);
            if (midi < 0 || midi > 127) continue;
            final ties = c.findElements('tie').map((t) => t.getAttribute('type')).toSet();
            final tieStart = ties.contains('start'), tieStop = ties.contains('stop');
            final fingering = c.getElement('notations')?.getElement('technical')?.getElement('fingering');
            final finger = int.tryParse(RegExp(r'\d').firstMatch(fingering?.innerText ?? '')?.group(0) ?? '');
            final hand = staves >= 2 ? (staff == 1 ? Hand.right : Hand.left) : Hand.unassigned;
            final note = ScoreNote(
              id: newId('n'),
              midi: midi,
              startTick: start + noteStart,
              durationTicks: dur,
              holdTicks: dur,
              tieStart: tieStart,
              tieStop: tieStop,
              voice: voice,
              staff: staves >= 2 ? staff : 1,
              hand: hand,
              track: partIndex,
              dots: dots,
              finger: finger,
              accidental: c.getElement('accidental') != null ? alter : null,
              confidence: 1.0,
              verified: false,
            );
            notes.add(note);

            final chainKey = '$staff:$midi';
            final chain = chains[chainKey];
            if (tieStop) {
              note.holdTicks = null;
              if (chain != null) {
                chain.total += dur;
                chain.first.holdTicks = chain.total;
                if (!tieStart) chains.remove(chainKey);
              }
            } else if (tieStart) {
              chains[chainKey] = _Chain(note, dur);
            }
        }
      }

      if (mIndex >= measures.length) {
        final nominal = time.measureTicks(kPpq);
        final implicit = m.getAttribute('implicit') == 'yes';
        final pickup = mIndex == 0 && maxPos > 0 && (implicit || (timeKnown && maxPos < nominal));
        final len = maxPos > 0 && (pickup || implicit || maxPos > nominal) ? maxPos : nominal;
        final number = m.getAttribute('number')?.trim();
        measures.add(Measure(
          index: mIndex,
          startTick: start,
          lengthTicks: len,
          number: (number == null || number.isEmpty) ? (pickup ? '0' : '${mIndex + 1}') : number,
          time: time,
          key: key,
          pickup: pickup,
        ));
      }
      mIndex++;
    }
  }

  static String? text(XmlElement? e) {
    final t = e?.innerText.trim();
    return (t == null || t.isEmpty) ? null : t;
  }

  static double _unitQuarters(String? unit, int dots) {
    const units = {
      'breve': 8.0,
      'whole': 4.0,
      'half': 2.0,
      'quarter': 1.0,
      'eighth': 0.5,
      '16th': 0.25,
      '32nd': 0.125,
    };
    var q = units[unit] ?? 1.0;
    var add = q / 2;
    for (var i = 0; i < dots; i++) {
      q += add;
      add /= 2;
    }
    return q;
  }
}
