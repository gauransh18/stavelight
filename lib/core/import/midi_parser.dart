import 'dart:typed_data';

import '../model/pitch.dart';
import '../model/score.dart';
import '../util/ids.dart';
import 'import_types.dart';

const _damaged = 'This MIDI file looks damaged or incomplete.';
const _drumChannel = 9;

/// Parses a Standard MIDI File (format 0/1/2, optionally RIFF RMID-wrapped) into a [Score].
///
/// Ticks are rescaled to [kPpq]. `durationTicks` and `holdTicks` both come from the real note-off;
/// sustain pedal (CC64) is stored as [PedalEvent]s and never lengthens a note.
Score parseMidi(Uint8List bytes, {required String title}) {
  final r = _Reader(_unwrapRmid(bytes));
  if (r.length < 14 || r.tag() != 'MThd') {
    throw ImportException('This file is not a MIDI file.', 'missing MThd header');
  }
  final headerLen = r.u32();
  if (headerLen < 6) throw ImportException(_damaged, 'header length $headerLen');
  final headerEnd = r.pos + headerLen;
  final format = r.u16();
  r.u16(); // declared track count; real chunks are counted instead
  final division = r.u16();
  if (division & 0x8000 != 0) {
    throw ImportException(
      'This MIDI file uses SMPTE timecode instead of musical beats, which isn\'t supported. '
          'Re-export it from your music app with standard (PPQ) timing.',
      'SMPTE division 0x${division.toRadixString(16)}',
    );
  }
  if (division == 0) throw ImportException(_damaged, 'division is 0');
  if (format > 2) throw ImportException('Unsupported MIDI format ($format).', 'format $format');
  r.pos = headerEnd;

  final c = _Collector();
  var trackIndex = 0;
  var offset = 0; // format 2: tracks play one after another
  while (r.pos + 8 <= r.length) {
    final id = r.tag();
    final len = r.u32();
    final start = r.pos;
    final end = (start + len).clamp(start, r.length);
    if (id == 'MTrk') {
      final last = _parseTrack(_Reader(r.data, start, end), trackIndex, offset, c);
      if (format == 2) offset = last;
      trackIndex++;
    }
    r.pos = end;
  }
  if (trackIndex == 0) throw ImportException(_damaged, 'no MTrk chunks');

  return _build(c, format, division, title);
}

Uint8List _unwrapRmid(Uint8List b) {
  bool at(int o, String s) => o + 4 <= b.length && String.fromCharCodes(b.sublist(o, o + 4)) == s;
  if (!at(0, 'RIFF') || !at(8, 'RMID')) return b;
  var p = 12;
  while (p + 8 <= b.length) {
    final len = b[p + 4] | b[p + 5] << 8 | b[p + 6] << 16 | b[p + 7] << 24;
    if (at(p, 'data')) {
      final end = (p + 8 + len).clamp(p + 8, b.length);
      return Uint8List.sublistView(b, p + 8, end);
    }
    p += 8 + len + (len & 1);
  }
  throw ImportException(_damaged, 'RMID without data chunk');
}

class _Reader {
  final Uint8List data;
  int pos;
  final int length;
  _Reader(this.data, [this.pos = 0, int? end]) : length = end ?? data.length;

  int u8() {
    if (pos >= length) throw const _Truncated();
    return data[pos++];
  }

  int u16() => u8() << 8 | u8();
  int u32() => u8() << 24 | u8() << 16 | u8() << 8 | u8();
  String tag() => String.fromCharCodes([u8(), u8(), u8(), u8()]);

  int vlq() {
    var v = 0;
    for (var i = 0; i < 4; i++) {
      final b = u8();
      v = (v << 7) | (b & 0x7F);
      if (b & 0x80 == 0) return v;
    }
    throw ImportException(_damaged, 'variable-length value too long');
  }

  Uint8List take(int n) {
    if (pos + n > length) throw const _Truncated();
    final out = Uint8List.sublistView(data, pos, pos + n);
    pos += n;
    return out;
  }
}

class _Truncated implements Exception {
  const _Truncated();
}

class _RawNote {
  final int track, channel, key, velocity, on;
  int off = 0;
  _RawNote(this.track, this.channel, this.key, this.velocity, this.on);
}

class _Collector {
  final notes = <_RawNote>[];
  final pedals = <(int tick, bool down)>[];
  final tempos = <(int tick, double bpm)>[];
  final times = <(int tick, TimeSignature ts)>[];
  final keys = <(int tick, KeySignature key)>[];
  final names = <int, String>{};
  final issues = <ScoreIssue>[];
  var drumNotes = 0;
  var dangling = 0;
}

/// Parses one MTrk chunk. Returns the absolute tick of its last event.
int _parseTrack(_Reader r, int track, int offset, _Collector c) {
  final open = <int, List<_RawNote>>{};
  var tick = offset;
  int? running;
  try {
    while (r.pos < r.length) {
      tick += r.vlq();
      var status = r.u8();
      if (status < 0x80) {
        if (running == null) throw ImportException(_damaged, 'data byte without status');
        status = running;
        r.pos--;
      }
      if (status == 0xFF) {
        final type = r.u8();
        final d = r.take(r.vlq());
        if (type == 0x2F) break;
        _meta(type, d, tick, track, c);
        continue;
      }
      if (status == 0xF0 || status == 0xF7) {
        r.take(r.vlq());
        continue;
      }
      if (status > 0xF0) throw ImportException(_damaged, 'unexpected status 0x${status.toRadixString(16)}');
      running = status;
      final kind = status & 0xF0, ch = status & 0x0F;
      final a = r.u8();
      final b = (kind == 0xC0 || kind == 0xD0) ? 0 : r.u8();
      final isOn = kind == 0x90 && b > 0;
      final isOff = kind == 0x80 || (kind == 0x90 && b == 0);
      if (isOn || isOff) {
        if (ch == _drumChannel) {
          if (isOn) c.drumNotes++;
          continue;
        }
        final k = ch << 7 | a;
        if (isOn) {
          final n = _RawNote(track, ch, a, b, tick);
          (open[k] ??= []).add(n);
          c.notes.add(n);
        } else {
          final q = open[k];
          if (q != null && q.isNotEmpty) q.removeAt(0).off = tick;
        }
      } else if (kind == 0xB0 && a == 64 && ch != _drumChannel) {
        c.pedals.add((tick, b >= 64));
      }
    }
  } on _Truncated {
    c.issues.add(ScoreIssue('Track ${track + 1} ends unexpectedly; the rest of it was skipped.'));
  }
  for (final q in open.values) {
    for (final n in q) {
      n.off = tick;
      c.dangling++;
    }
  }
  return tick;
}

void _meta(int type, Uint8List d, int tick, int track, _Collector c) {
  switch (type) {
    case 0x03:
      final name = String.fromCharCodes(d.where((b) => b >= 0x20)).trim();
      if (name.isNotEmpty) c.names.putIfAbsent(track, () => name);
    case 0x51:
      if (d.length >= 3) {
        final us = d[0] << 16 | d[1] << 8 | d[2];
        if (us > 0) c.tempos.add((tick, 60000000 / us));
      }
    case 0x58:
      if (d.length >= 2 && d[0] > 0 && d[1] < 7) c.times.add((tick, TimeSignature(d[0], 1 << d[1])));
    case 0x59:
      if (d.length >= 2) {
        final sf = d[0] > 127 ? d[0] - 256 : d[0];
        c.keys.add((tick, KeySignature(sf.clamp(-7, 7), minor: d[1] == 1)));
      }
  }
}

/// Last value per tick, sorted by tick.
List<(int, T)> _byTick<T>(List<(int, T)> events, int Function(int) scale) {
  final m = <int, T>{};
  for (final e in events) {
    m[scale(e.$1)] = e.$2;
  }
  return (m.keys.toList()..sort()).map((t) => (t, m[t] as T)).toList();
}

T _activeAt<T>(List<(int, T)> events, int tick, T fallback) {
  var v = fallback;
  for (final e in events) {
    if (e.$1 > tick) break;
    v = e.$2;
  }
  return v;
}

Score _build(_Collector c, int format, int division, String title) {
  int scale(int t) => (t * kPpq + division ~/ 2) ~/ division;
  final issues = [...c.issues];
  if (c.drumNotes > 0) {
    issues.add(ScoreIssue('${c.drumNotes} drum notes (channel 10) were left out.', severity: 'info'));
  }
  if (c.dangling > 0) {
    issues.add(ScoreIssue('${c.dangling} notes had no note-off and were ended at the end of their track.'));
  }
  if (c.notes.isEmpty) {
    throw ImportException(
      c.drumNotes > 0 ? 'This MIDI file only contains drums — no piano notes to practise.' : 'This MIDI file has no notes.',
    );
  }

  // Group notes into tracks: per channel for format 0, per track chunk otherwise.
  int groupOf(_RawNote n) => format == 0 ? n.channel : n.track;
  final groups = <int, List<_RawNote>>{};
  for (final n in c.notes) {
    (groups[groupOf(n)] ??= []).add(n);
  }
  final keys = groups.keys.toList()..sort();
  final twoHands = keys.length == 2;
  final channelsInTrack0 = format == 0 ? keys.length : 0;
  final tracks = <TrackInfo>[];
  final notes = <ScoreNote>[];
  for (var i = 0; i < keys.length; i++) {
    final raw = groups[keys[i]]!;
    final hand = twoHands ? (i == 0 ? Hand.right : Hand.left) : Hand.unassigned;
    String name;
    if (format == 0) {
      final base = c.names[0];
      name = base == null ? 'Channel ${keys[i] + 1}' : (channelsInTrack0 > 1 ? '$base (ch ${keys[i] + 1})' : base);
    } else {
      name = c.names[keys[i]] ?? 'Track ${keys[i] + 1}';
    }
    var lo = 127, hi = 0;
    for (final n in raw) {
      if (n.key < lo) lo = n.key;
      if (n.key > hi) hi = n.key;
      final start = scale(n.on);
      final len = (scale(n.off) - start).clamp(1, 1 << 40);
      notes.add(ScoreNote(
        id: newId('n'),
        midi: n.key,
        startTick: start,
        durationTicks: len,
        holdTicks: len,
        hand: hand,
        staff: switch (hand) { Hand.right => 1, Hand.left => 2, Hand.unassigned => n.key >= 60 ? 1 : 2 },
        track: i,
        velocity: n.velocity,
        confidence: 1.0,
        verified: false,
      ));
    }
    tracks.add(TrackInfo(index: i, name: name, noteCount: raw.length, lowest: lo, highest: hi, hand: hand));
  }

  // Sustain pedal: merge all channels, keep state changes only. Initial state is up.
  final pedalRaw = [for (var i = 0; i < c.pedals.length; i++) (scale(c.pedals[i].$1), c.pedals[i].$2, i)]
    ..sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$3.compareTo(b.$3));
  final pedals = <PedalEvent>[];
  var down = false;
  for (final p in pedalRaw) {
    if (p.$2 == down) continue;
    down = p.$2;
    pedals.add(PedalEvent(
      id: newId('p'),
      tick: p.$1,
      type: down ? PedalType.down : PedalType.up,
      confidence: 1.0,
      verified: true,
      source: 'midi',
    ));
  }

  final tempos = [for (final t in _byTick(c.tempos, scale)) TempoEvent(t.$1, t.$2)];
  if (tempos.isEmpty || tempos.first.tick > 0) tempos.insert(0, TempoEvent(0, 120));

  final times = _byTick(c.times, scale);
  final keySigs = _byTick(c.keys, scale);
  var end = 0;
  for (final n in notes) {
    if (n.startTick + n.effectiveHoldTicks > end) end = n.startTick + n.effectiveHoldTicks;
  }
  final measures = <Measure>[];
  var tick = 0;
  while (tick < end || measures.isEmpty) {
    final ts = _activeAt(times, tick, const TimeSignature(4, 4));
    var len = ts.measureTicks(kPpq);
    for (final t in times) {
      if (t.$1 > tick && t.$1 < tick + len) {
        len = t.$1 - tick;
        break;
      }
    }
    if (len <= 0) len = kPpq * 4;
    measures.add(Measure(
      index: measures.length,
      startTick: tick,
      lengthTicks: len,
      number: '${measures.length + 1}',
      time: ts,
      key: _activeAt(keySigs, tick, const KeySignature(0)),
    ));
    tick += len;
  }

  final score = Score(
    title: title,
    origin: ScoreOrigin.midi,
    review: ReviewState.parsed,
    notes: notes,
    pedals: [...pedals],
    tempos: tempos,
    measures: measures,
    tracks: tracks,
    issues: issues,
    pedalDataPresent: c.pedals.isNotEmpty,
  )..normalize();
  // normalize()'s sort is unstable; restore source order so same-tick up/down pairs stay up-then-down.
  return score..pedals = pedals;
}
