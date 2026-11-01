import 'pitch.dart';

/// Ticks per quarter note used by every score in the app. Parsers rescale to this.
const int kPpq = 480;

enum Hand { right, left, unassigned }

enum ScoreOrigin { midi, musicxml, omr, manual }

/// Overall review state. OMR scores start as [recognized]; only the user can move a score to [verified].
enum ReviewState { parsed, recognized, verified }

enum PedalType { down, up }

enum ClefKind { treble, bass }

Hand _hand(String? s) => Hand.values.firstWhere((h) => h.name == s, orElse: () => Hand.unassigned);

/// One notehead. Written duration, key-hold duration and pedal-sustained sound are kept apart:
/// - [durationTicks] is the written rhythmic value of this notehead only (dots/tuplets applied).
/// - [holdTicks] is how long the key is expected to be held. MIDI: from the real note-off.
///   Notation: the sum of the tie chain, set on the first note of the chain (null on continuation notes).
/// - Sound after key release (pedal) is derived from [Score.pedals]. It is never folded into [holdTicks].
class ScoreNote {
  String id;
  int midi;
  int startTick;
  int durationTicks;
  int? holdTicks;
  bool tieStart;
  bool tieStop;
  int voice;
  int staff; // 1 = upper (treble), 2 = lower (bass)
  Hand hand;
  int measureIndex;
  int track; // source track/part index
  int dots;
  int? finger;
  int velocity;

  /// Explicit accidental shown on the notehead (-2..2), null = follows key signature.
  int? accidental;

  /// 0..1. Parsed digital imports use 1.0. OMR provides its own estimate.
  double confidence;
  bool verified;

  /// Why this note was flagged (OMR), shown in review.
  List<String> flags;

  ScoreNote({
    required this.id,
    required this.midi,
    required this.startTick,
    required this.durationTicks,
    this.holdTicks,
    this.tieStart = false,
    this.tieStop = false,
    this.voice = 1,
    this.staff = 1,
    this.hand = Hand.unassigned,
    this.measureIndex = 0,
    this.track = 0,
    this.dots = 0,
    this.finger,
    this.velocity = 80,
    this.accidental,
    this.confidence = 1.0,
    this.verified = false,
    List<String>? flags,
  }) : flags = flags ?? [];

  int get endTick => startTick + durationTicks;

  /// Expected key-hold, defaulting to written duration when unset.
  int get effectiveHoldTicks => holdTicks ?? durationTicks;

  bool get isTieContinuation => tieStop;

  ScoreNote copy() => ScoreNote.fromJson(toJson());

  Map<String, dynamic> toJson() => {
        'id': id,
        'midi': midi,
        'start': startTick,
        'dur': durationTicks,
        if (holdTicks != null) 'hold': holdTicks,
        if (tieStart) 'tieStart': true,
        if (tieStop) 'tieStop': true,
        'voice': voice,
        'staff': staff,
        'hand': hand.name,
        'measure': measureIndex,
        'track': track,
        if (dots != 0) 'dots': dots,
        if (finger != null) 'finger': finger,
        'vel': velocity,
        if (accidental != null) 'acc': accidental,
        'conf': confidence,
        'verified': verified,
        if (flags.isNotEmpty) 'flags': flags,
      };

  factory ScoreNote.fromJson(Map<String, dynamic> j) => ScoreNote(
        id: j['id'] as String,
        midi: j['midi'] as int,
        startTick: j['start'] as int,
        durationTicks: j['dur'] as int,
        holdTicks: j['hold'] as int?,
        tieStart: j['tieStart'] as bool? ?? false,
        tieStop: j['tieStop'] as bool? ?? false,
        voice: j['voice'] as int? ?? 1,
        staff: j['staff'] as int? ?? 1,
        hand: _hand(j['hand'] as String?),
        measureIndex: j['measure'] as int? ?? 0,
        track: j['track'] as int? ?? 0,
        dots: j['dots'] as int? ?? 0,
        finger: j['finger'] as int?,
        velocity: j['vel'] as int? ?? 80,
        accidental: j['acc'] as int?,
        confidence: (j['conf'] as num?)?.toDouble() ?? 1.0,
        verified: j['verified'] as bool? ?? false,
        flags: (j['flags'] as List?)?.cast<String>(),
      );
}

class ScoreRest {
  int startTick;
  int durationTicks;
  int staff;
  int voice;
  int measureIndex;
  double confidence;
  ScoreRest({
    required this.startTick,
    required this.durationTicks,
    this.staff = 1,
    this.voice = 1,
    this.measureIndex = 0,
    this.confidence = 1.0,
  });

  Map<String, dynamic> toJson() => {
        'start': startTick,
        'dur': durationTicks,
        'staff': staff,
        'voice': voice,
        'measure': measureIndex,
        'conf': confidence,
      };
  factory ScoreRest.fromJson(Map<String, dynamic> j) => ScoreRest(
        startTick: j['start'] as int,
        durationTicks: j['dur'] as int,
        staff: j['staff'] as int? ?? 1,
        voice: j['voice'] as int? ?? 1,
        measureIndex: j['measure'] as int? ?? 0,
        confidence: (j['conf'] as num?)?.toDouble() ?? 1.0,
      );
}

/// Sustain (damper) pedal change. Kept separate from note on/off.
class PedalEvent {
  String id;
  int tick;
  PedalType type;
  double confidence;
  bool verified;

  /// 'midi', 'musicxml', 'omr', 'user'.
  String source;

  PedalEvent({
    required this.id,
    required this.tick,
    required this.type,
    this.confidence = 1.0,
    this.verified = false,
    this.source = 'user',
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'tick': tick,
        'type': type.name,
        'conf': confidence,
        'verified': verified,
        'source': source,
      };
  factory PedalEvent.fromJson(Map<String, dynamic> j) => PedalEvent(
        id: j['id'] as String,
        tick: j['tick'] as int,
        type: j['type'] == 'up' ? PedalType.up : PedalType.down,
        confidence: (j['conf'] as num?)?.toDouble() ?? 1.0,
        verified: j['verified'] as bool? ?? false,
        source: j['source'] as String? ?? 'user',
      );
}

class TempoEvent {
  int tick;
  double bpm; // quarter notes per minute
  TempoEvent(this.tick, this.bpm);
  Map<String, dynamic> toJson() => {'tick': tick, 'bpm': bpm};
  factory TempoEvent.fromJson(Map<String, dynamic> j) => TempoEvent(j['tick'] as int, (j['bpm'] as num).toDouble());
}

class Measure {
  int index;
  int startTick;
  int lengthTicks;
  String number; // display label; pickup is often "0"
  TimeSignature time;
  KeySignature key;
  bool pickup;
  double confidence;
  bool verified;
  List<String> flags;

  /// OMR only: page index and normalized x-range on the source page, for "show original".
  int? page;
  double? x0, x1, y0, y1;

  Measure({
    required this.index,
    required this.startTick,
    required this.lengthTicks,
    required this.number,
    required this.time,
    required this.key,
    this.pickup = false,
    this.confidence = 1.0,
    this.verified = false,
    List<String>? flags,
    this.page,
    this.x0,
    this.x1,
    this.y0,
    this.y1,
  }) : flags = flags ?? [];

  int get endTick => startTick + lengthTicks;

  Map<String, dynamic> toJson() => {
        'index': index,
        'start': startTick,
        'len': lengthTicks,
        'number': number,
        'time': time.toJson(),
        'key': key.toJson(),
        if (pickup) 'pickup': true,
        'conf': confidence,
        'verified': verified,
        if (flags.isNotEmpty) 'flags': flags,
        if (page != null) 'page': page,
        if (x0 != null) 'x0': x0,
        if (x1 != null) 'x1': x1,
        if (y0 != null) 'y0': y0,
        if (y1 != null) 'y1': y1,
      };
  factory Measure.fromJson(Map<String, dynamic> j) => Measure(
        index: j['index'] as int,
        startTick: j['start'] as int,
        lengthTicks: j['len'] as int,
        number: j['number'] as String? ?? '${j['index']}',
        time: TimeSignature.fromJson((j['time'] as Map).cast<String, dynamic>()),
        key: KeySignature.fromJson((j['key'] as Map).cast<String, dynamic>()),
        pickup: j['pickup'] as bool? ?? false,
        confidence: (j['conf'] as num?)?.toDouble() ?? 1.0,
        verified: j['verified'] as bool? ?? false,
        flags: (j['flags'] as List?)?.cast<String>(),
        page: j['page'] as int?,
        x0: (j['x0'] as num?)?.toDouble(),
        x1: (j['x1'] as num?)?.toDouble(),
        y0: (j['y0'] as num?)?.toDouble(),
        y1: (j['y1'] as num?)?.toDouble(),
      );
}

/// A track (MIDI) or part (MusicXML) found in the source, used for part selection on import.
class TrackInfo {
  int index;
  String name;
  int noteCount;
  int lowest;
  int highest;
  bool selected;
  Hand hand;
  TrackInfo({
    required this.index,
    required this.name,
    required this.noteCount,
    required this.lowest,
    required this.highest,
    this.selected = true,
    this.hand = Hand.unassigned,
  });
  Map<String, dynamic> toJson() => {
        'index': index,
        'name': name,
        'count': noteCount,
        'lo': lowest,
        'hi': highest,
        'selected': selected,
        'hand': hand.name,
      };
  factory TrackInfo.fromJson(Map<String, dynamic> j) => TrackInfo(
        index: j['index'] as int,
        name: j['name'] as String? ?? 'Track',
        noteCount: j['count'] as int? ?? 0,
        lowest: j['lo'] as int? ?? 0,
        highest: j['hi'] as int? ?? 127,
        selected: j['selected'] as bool? ?? true,
        hand: _hand(j['hand'] as String?),
      );
}

/// A per-score issue found during import ("Clef assumed — please confirm").
class ScoreIssue {
  final String message;
  final int? measureIndex;
  final String severity; // 'info' | 'warning' | 'error'
  ScoreIssue(this.message, {this.measureIndex, this.severity = 'warning'});
  Map<String, dynamic> toJson() => {'msg': message, if (measureIndex != null) 'm': measureIndex, 'sev': severity};
  factory ScoreIssue.fromJson(Map<String, dynamic> j) =>
      ScoreIssue(j['msg'] as String, measureIndex: j['m'] as int?, severity: j['sev'] as String? ?? 'warning');
}

class Score {
  String title;
  String? composer;
  ScoreOrigin origin;
  ReviewState review;
  List<ScoreNote> notes;
  List<ScoreRest> rests;
  List<PedalEvent> pedals;
  List<TempoEvent> tempos;
  List<Measure> measures;
  List<TrackInfo> tracks;
  List<ScoreIssue> issues;

  /// Pedal data status for the UI: true when the source had any pedal information at all.
  bool pedalDataPresent;

  /// Playable range of the target instrument (88-key piano by default).
  int rangeLow;
  int rangeHigh;

  /// Split point used when hands are assigned automatically (notes >= split go to right hand).
  int handSplit;

  Score({
    required this.title,
    this.composer,
    required this.origin,
    this.review = ReviewState.parsed,
    List<ScoreNote>? notes,
    List<ScoreRest>? rests,
    List<PedalEvent>? pedals,
    List<TempoEvent>? tempos,
    List<Measure>? measures,
    List<TrackInfo>? tracks,
    List<ScoreIssue>? issues,
    this.pedalDataPresent = false,
    this.rangeLow = 21,
    this.rangeHigh = 108,
    this.handSplit = 60,
  })  : notes = notes ?? [],
        rests = rests ?? [],
        pedals = pedals ?? [],
        tempos = tempos ?? [TempoEvent(0, 100)],
        measures = measures ?? [],
        tracks = tracks ?? [],
        issues = issues ?? [];

  int get endTick {
    var end = measures.isEmpty ? 0 : measures.last.endTick;
    for (final n in notes) {
      final e = n.startTick + n.effectiveHoldTicks;
      if (e > end) end = e;
    }
    return end;
  }

  TempoMap get tempoMap => TempoMap(tempos);

  int measureIndexAt(int tick) {
    if (measures.isEmpty) return 0;
    var lo = 0, hi = measures.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (measures[mid].startTick <= tick) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  /// Notes or measures that still need review (low confidence, flagged, unverified).
  int get uncertainCount =>
      notes.where((n) => !n.verified && (n.confidence < 0.75 || n.flags.isNotEmpty)).length +
      measures.where((m) => !m.verified && (m.confidence < 0.75 || m.flags.isNotEmpty)).length +
      pedals.where((p) => !p.verified && p.confidence < 0.75).length;

  /// Sort notes and re-derive measure indices. Call after edits that move notes.
  void normalize() {
    notes.sort((a, b) {
      final c = a.startTick.compareTo(b.startTick);
      return c != 0 ? c : a.midi.compareTo(b.midi);
    });
    // Same tick: release before press, so a pedal "change" stays up-then-down after sorting.
    pedals.sort((a, b) {
      final c = a.tick.compareTo(b.tick);
      if (c != 0) return c;
      return (a.type == PedalType.up ? 0 : 1) - (b.type == PedalType.up ? 0 : 1);
    });
    tempos.sort((a, b) => a.tick.compareTo(b.tick));
    for (final n in notes) {
      n.measureIndex = measureIndexAt(n.startTick);
    }
    for (final r in rests) {
      r.measureIndex = measureIndexAt(r.startTick);
    }
  }

  /// Is the sustain pedal down at [tick]? Only verified or high-confidence events count unless [includeUncertain].
  bool pedalDownAt(int tick, {bool includeUncertain = true}) {
    var down = false;
    for (final p in pedals) {
      if (p.tick > tick) break;
      if (!includeUncertain && !p.verified && p.confidence < 0.75) continue;
      down = p.type == PedalType.down;
    }
    return down;
  }

  /// Sounding end of a note: key release, extended to the next pedal-up if the pedal is down at release.
  /// Display/playback only — never used to score how long a key is held.
  /// Unverified low-confidence pedal candidates (e.g. from OMR) are ignored here.
  int soundingEndTick(ScoreNote n) {
    final release = n.startTick + n.effectiveHoldTicks;
    if (!pedalDownAt(release, includeUncertain: false)) return release;
    for (final p in pedals) {
      if (p.tick > release && p.type == PedalType.up && (p.verified || p.confidence >= 0.75)) return p.tick;
    }
    return endTick;
  }

  Score copy() => Score.fromJson(toJson());

  Map<String, dynamic> toJson() => {
        'v': 1,
        'title': title,
        if (composer != null) 'composer': composer,
        'origin': origin.name,
        'review': review.name,
        'notes': notes.map((e) => e.toJson()).toList(),
        'rests': rests.map((e) => e.toJson()).toList(),
        'pedals': pedals.map((e) => e.toJson()).toList(),
        'tempos': tempos.map((e) => e.toJson()).toList(),
        'measures': measures.map((e) => e.toJson()).toList(),
        'tracks': tracks.map((e) => e.toJson()).toList(),
        'issues': issues.map((e) => e.toJson()).toList(),
        'pedalData': pedalDataPresent,
        'rangeLow': rangeLow,
        'rangeHigh': rangeHigh,
        'split': handSplit,
      };

  factory Score.fromJson(Map<String, dynamic> j) {
    List<Map<String, dynamic>> list(String k) =>
        ((j[k] as List?) ?? const []).map((e) => (e as Map).cast<String, dynamic>()).toList();
    return Score(
      title: j['title'] as String? ?? 'Untitled',
      composer: j['composer'] as String?,
      origin: ScoreOrigin.values.firstWhere((o) => o.name == j['origin'], orElse: () => ScoreOrigin.manual),
      review: ReviewState.values.firstWhere((o) => o.name == j['review'], orElse: () => ReviewState.parsed),
      notes: list('notes').map(ScoreNote.fromJson).toList(),
      rests: list('rests').map(ScoreRest.fromJson).toList(),
      pedals: list('pedals').map(PedalEvent.fromJson).toList(),
      tempos: list('tempos').map(TempoEvent.fromJson).toList(),
      measures: list('measures').map(Measure.fromJson).toList(),
      tracks: list('tracks').map(TrackInfo.fromJson).toList(),
      issues: list('issues').map(ScoreIssue.fromJson).toList(),
      pedalDataPresent: j['pedalData'] as bool? ?? false,
      rangeLow: j['rangeLow'] as int? ?? 21,
      rangeHigh: j['rangeHigh'] as int? ?? 108,
      handSplit: j['split'] as int? ?? 60,
    );
  }
}

/// Converts between ticks and seconds using a piecewise-constant tempo map.
class TempoMap {
  final List<TempoEvent> _events;
  final List<double> _secAt; // seconds at each event's tick

  TempoMap(List<TempoEvent> events)
      : _events = events.isEmpty ? [TempoEvent(0, 120)] : ([...events]..sort((a, b) => a.tick.compareTo(b.tick))),
        _secAt = [] {
    if (_events.first.tick != 0) _events.insert(0, TempoEvent(0, _events.first.bpm));
    var sec = 0.0;
    for (var i = 0; i < _events.length; i++) {
      if (i > 0) {
        sec += (_events[i].tick - _events[i - 1].tick) * _secPerTick(_events[i - 1].bpm);
      }
      _secAt.add(sec);
    }
  }

  static double _secPerTick(double bpm) => 60.0 / (bpm * kPpq);

  double bpmAt(int tick) {
    var bpm = _events.first.bpm;
    for (final e in _events) {
      if (e.tick > tick) break;
      bpm = e.bpm;
    }
    return bpm;
  }

  double secondsAt(num tick) {
    var i = _events.length - 1;
    while (i > 0 && _events[i].tick > tick) {
      i--;
    }
    return _secAt[i] + (tick - _events[i].tick) * _secPerTick(_events[i].bpm);
  }

  double tickAt(double seconds) {
    var i = _secAt.length - 1;
    while (i > 0 && _secAt[i] > seconds) {
      i--;
    }
    return _events[i].tick + (seconds - _secAt[i]) / _secPerTick(_events[i].bpm);
  }
}
