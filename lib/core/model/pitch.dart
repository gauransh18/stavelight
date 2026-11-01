import 'dart:math' as math;

/// Pitch helpers. MIDI note numbers throughout; middle C = 60 = "C4".
class Pitch {
  static const sharpNames = ['C', 'C♯', 'D', 'D♯', 'E', 'F', 'F♯', 'G', 'G♯', 'A', 'A♯', 'B'];
  static const flatNames = ['C', 'D♭', 'D', 'E♭', 'E', 'F', 'G♭', 'G', 'A♭', 'A', 'B♭', 'B'];
  static const asciiSharp = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];

  /// Semitone offset of each diatonic step (C D E F G A B) from C.
  static const stepSemitones = [0, 2, 4, 5, 7, 9, 11];
  static const stepLetters = ['C', 'D', 'E', 'F', 'G', 'A', 'B'];

  static int octaveOf(int midi) => (midi ~/ 12) - 1;
  static int pitchClass(int midi) => midi % 12;

  static String name(int midi, {bool flats = false, bool withOctave = true}) {
    final pc = pitchClass(midi);
    final n = flats ? flatNames[pc] : sharpNames[pc];
    return withOctave ? '$n${octaveOf(midi)}' : n;
  }

  static String spokenName(int midi) {
    final pc = asciiSharp[pitchClass(midi)].replaceAll('#', ' sharp');
    return '$pc ${octaveOf(midi)}';
  }

  static bool isBlack(int midi) => const [1, 3, 6, 8, 10].contains(pitchClass(midi));

  /// MIDI from diatonic step (0=C..6=B), alter (-2..2) and octave (4 = middle).
  static int fromStep(int step, int alter, int octave) => (octave + 1) * 12 + stepSemitones[step] + alter;

  /// Diatonic index: C-1 = 0, counts letters (C D E F G A B) upward. Used for staff placement.
  static int diatonicIndex(int step, int octave) => (octave + 1) * 7 + step;

  static double frequency(int midi, {double a4 = 440}) => a4 * math.pow(2, (midi - 69) / 12).toDouble();

  /// Fractional MIDI number for a frequency.
  static double midiFromFrequency(double hz, {double a4 = 440}) => 69 + 12 * (math.log(hz / a4) / math.ln2);
}

/// Key signature by circle-of-fifths count: -7 (7 flats) .. +7 (7 sharps).
class KeySignature {
  final int fifths;
  final bool minor;
  const KeySignature(this.fifths, {this.minor = false});

  static const _sharpOrder = [3, 0, 4, 1, 5, 2, 6]; // F C G D A E B (step indices)
  static const _flatOrder = [6, 2, 5, 1, 4, 0, 3]; // B E A D G C F

  /// Alteration the key applies to a diatonic step (0=C..6=B).
  int alterFor(int step) {
    if (fifths > 0 && _sharpOrder.take(fifths).contains(step)) return 1;
    if (fifths < 0 && _flatOrder.take(-fifths).contains(step)) return -1;
    return 0;
  }

  String get label {
    const majors = ['C♭', 'G♭', 'D♭', 'A♭', 'E♭', 'B♭', 'F', 'C', 'G', 'D', 'A', 'E', 'B', 'F♯', 'C♯'];
    const minors = ['A♭', 'E♭', 'B♭', 'F', 'C', 'G', 'D', 'A', 'E', 'B', 'F♯', 'C♯', 'G♯', 'D♯', 'A♯'];
    final i = fifths.clamp(-7, 7) + 7;
    return minor ? '${minors[i]} minor' : '${majors[i]} major';
  }

  bool get prefersFlats => fifths < 0;

  Map<String, dynamic> toJson() => {'fifths': fifths, 'minor': minor};
  factory KeySignature.fromJson(Map<String, dynamic> j) =>
      KeySignature(j['fifths'] as int? ?? 0, minor: j['minor'] as bool? ?? false);

  @override
  bool operator ==(Object other) => other is KeySignature && other.fifths == fifths && other.minor == minor;
  @override
  int get hashCode => Object.hash(fifths, minor);
}

class TimeSignature {
  final int beats;
  final int beatType;
  const TimeSignature(this.beats, this.beatType);

  /// Measure length in ticks at [ppq] ticks per quarter.
  int measureTicks(int ppq) => (beats * ppq * 4) ~/ beatType;

  /// Ticks per metronome beat. Compound meters (6/8, 9/8, 12/8) beat in dotted quarters.
  int beatTicks(int ppq) {
    final unit = (ppq * 4) ~/ beatType;
    if (beatType == 8 && beats % 3 == 0 && beats > 3) return unit * 3;
    return unit;
  }

  int beatsPerMeasure(int ppq) => measureTicks(ppq) ~/ beatTicks(ppq);

  String get label => '$beats/$beatType';

  Map<String, dynamic> toJson() => {'beats': beats, 'beatType': beatType};
  factory TimeSignature.fromJson(Map<String, dynamic> j) =>
      TimeSignature(j['beats'] as int? ?? 4, j['beatType'] as int? ?? 4);

  @override
  bool operator ==(Object other) => other is TimeSignature && other.beats == beats && other.beatType == beatType;
  @override
  int get hashCode => Object.hash(beats, beatType);
}
