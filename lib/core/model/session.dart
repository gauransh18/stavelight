enum PracticeMode { follow, wait, freePlay }

enum HandsSelection { both, right, left }

enum InputKind { midi, mic, none }

/// Per-measure result within a session.
class MeasureStat {
  int expected = 0;
  int correct = 0;
  int errors = 0; // wrong pitch / octave / missed with confident input
  int uncertain = 0;
  MeasureStat();
  double? get accuracy => expected - uncertain <= 0 ? null : correct / (expected - uncertain);
  Map<String, dynamic> toJson() => {'e': expected, 'c': correct, 'x': errors, 'u': uncertain};
  factory MeasureStat.fromJson(Map<String, dynamic> j) => MeasureStat()
    ..expected = j['e'] as int? ?? 0
    ..correct = j['c'] as int? ?? 0
    ..errors = j['x'] as int? ?? 0
    ..uncertain = j['u'] as int? ?? 0;
}

/// Stored summary of one practice session. All accuracy numbers are estimates; mic results more so.
class PracticeSession {
  final String id;
  final String? pieceId;
  final DateTime startedAt;
  int durationSec;
  PracticeMode mode;
  InputKind input;
  HandsSelection hands;
  double tempoPct;
  int transpose;
  int? loopStart;
  int? loopEnd;

  int correct = 0;
  int early = 0;
  int late = 0;
  int wrongPitch = 0;
  int octaveMismatch = 0;
  int missed = 0;
  int uncertain = 0;
  int skipped = 0;
  int notAssessed = 0;
  int extraNotes = 0;
  int earlyReleases = 0;
  int pedalChecks = 0;
  int pedalOnTime = 0;

  /// Standard deviation of timing offsets (ms) for matched notes; null when too few samples.
  double? timingSpreadMs;
  double? meanOffsetMs;
  int measuresCompleted = 0;
  Map<int, MeasureStat> perMeasure = {};
  Map<int, int> missedPitches = {};

  /// True when input quality was too low to draw conclusions (mostly uncertain detections).
  bool lowQuality = false;

  PracticeSession({
    required this.id,
    required this.pieceId,
    required this.startedAt,
    this.durationSec = 0,
    this.mode = PracticeMode.follow,
    this.input = InputKind.none,
    this.hands = HandsSelection.both,
    this.tempoPct = 100,
    this.transpose = 0,
    this.loopStart,
    this.loopEnd,
  });

  int get assessed => correct + early + late + wrongPitch + octaveMismatch + missed;

  /// Pitch accuracy estimate: right pitch (on time, early or late) over confidently assessed notes.
  double? get pitchAccuracy => assessed < 3 ? null : (correct + early + late) / assessed;

  /// Share of correctly pitched notes that were also on time.
  double? get timingAccuracy {
    final hit = correct + early + late;
    return hit < 3 ? null : correct / hit;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'pieceId': pieceId,
        'startedAt': startedAt.toIso8601String(),
        'durationSec': durationSec,
        'mode': mode.name,
        'input': input.name,
        'hands': hands.name,
        'tempoPct': tempoPct,
        'transpose': transpose,
        'loopStart': loopStart,
        'loopEnd': loopEnd,
        'correct': correct,
        'early': early,
        'late': late,
        'wrongPitch': wrongPitch,
        'octave': octaveMismatch,
        'missed': missed,
        'uncertain': uncertain,
        'skipped': skipped,
        'notAssessed': notAssessed,
        'extra': extraNotes,
        'earlyReleases': earlyReleases,
        'pedalChecks': pedalChecks,
        'pedalOnTime': pedalOnTime,
        'timingSpreadMs': timingSpreadMs,
        'meanOffsetMs': meanOffsetMs,
        'measuresCompleted': measuresCompleted,
        'perMeasure': perMeasure.map((k, v) => MapEntry('$k', v.toJson())),
        'missedPitches': missedPitches.map((k, v) => MapEntry('$k', v)),
        'lowQuality': lowQuality,
      };

  factory PracticeSession.fromJson(Map<String, dynamic> j) {
    T e<T extends Enum>(List<T> values, Object? v, T d) => values.firstWhere((x) => x.name == v, orElse: () => d);
    return PracticeSession(
      id: j['id'] as String,
      pieceId: j['pieceId'] as String?,
      startedAt: DateTime.parse(j['startedAt'] as String),
      durationSec: j['durationSec'] as int? ?? 0,
      mode: e(PracticeMode.values, j['mode'], PracticeMode.follow),
      input: e(InputKind.values, j['input'], InputKind.none),
      hands: e(HandsSelection.values, j['hands'], HandsSelection.both),
      tempoPct: (j['tempoPct'] as num?)?.toDouble() ?? 100,
      transpose: j['transpose'] as int? ?? 0,
      loopStart: j['loopStart'] as int?,
      loopEnd: j['loopEnd'] as int?,
    )
      ..correct = j['correct'] as int? ?? 0
      ..early = j['early'] as int? ?? 0
      ..late = j['late'] as int? ?? 0
      ..wrongPitch = j['wrongPitch'] as int? ?? 0
      ..octaveMismatch = j['octave'] as int? ?? 0
      ..missed = j['missed'] as int? ?? 0
      ..uncertain = j['uncertain'] as int? ?? 0
      ..skipped = j['skipped'] as int? ?? 0
      ..notAssessed = j['notAssessed'] as int? ?? 0
      ..extraNotes = j['extra'] as int? ?? 0
      ..earlyReleases = j['earlyReleases'] as int? ?? 0
      ..pedalChecks = j['pedalChecks'] as int? ?? 0
      ..pedalOnTime = j['pedalOnTime'] as int? ?? 0
      ..timingSpreadMs = (j['timingSpreadMs'] as num?)?.toDouble()
      ..meanOffsetMs = (j['meanOffsetMs'] as num?)?.toDouble()
      ..measuresCompleted = j['measuresCompleted'] as int? ?? 0
      ..perMeasure = ((j['perMeasure'] as Map?) ?? const {})
          .map((k, v) => MapEntry(int.parse(k as String), MeasureStat.fromJson((v as Map).cast<String, dynamic>())))
      ..missedPitches =
          ((j['missedPitches'] as Map?) ?? const {}).map((k, v) => MapEntry(int.parse(k as String), v as int))
      ..lowQuality = j['lowQuality'] as bool? ?? false;
  }
}
