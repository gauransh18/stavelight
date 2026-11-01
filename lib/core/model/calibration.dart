import 'session.dart';

/// Saved calibration for one input setup (a MIDI device or the microphone on this device).
class CalibrationProfile {
  /// 'mic' or 'midi:' followed by the device name.
  final String key;
  final InputKind input;

  /// Tuning reference for pitch detection. Pianos are not always at 440 Hz.
  double a4Hz;

  /// Octave correction applied to detected notes (mic: harmonic/subharmonic errors).
  int octaveOffset;

  /// Semitone correction for keyboards that send transposed notes (MIDI).
  int semitoneOffset;

  /// Mic sensitivity 0..1 (higher = accepts quieter/less clean signals).
  double sensitivity;

  /// Ambient RMS measured during calibration (mic only).
  double noiseFloor;
  bool confirmed;
  DateTime? calibratedAt;

  CalibrationProfile({
    required this.key,
    required this.input,
    this.a4Hz = 440,
    this.octaveOffset = 0,
    this.semitoneOffset = 0,
    this.sensitivity = 0.5,
    this.noiseFloor = 0,
    this.confirmed = false,
    this.calibratedAt,
  });

  int get totalOffset => octaveOffset * 12 + semitoneOffset;

  /// Apply corrections to a raw detected MIDI number.
  int correct(int rawMidi) => rawMidi + totalOffset;

  Map<String, dynamic> toJson() => {
        'key': key,
        'input': input.name,
        'a4': a4Hz,
        'oct': octaveOffset,
        'semi': semitoneOffset,
        'sens': sensitivity,
        'noise': noiseFloor,
        'confirmed': confirmed,
        if (calibratedAt != null) 'at': calibratedAt!.toIso8601String(),
      };

  factory CalibrationProfile.fromJson(Map<String, dynamic> j) => CalibrationProfile(
        key: j['key'] as String,
        input: InputKind.values.firstWhere((i) => i.name == j['input'], orElse: () => InputKind.mic),
        a4Hz: (j['a4'] as num?)?.toDouble() ?? 440,
        octaveOffset: j['oct'] as int? ?? 0,
        semitoneOffset: j['semi'] as int? ?? 0,
        sensitivity: (j['sens'] as num?)?.toDouble() ?? 0.5,
        noiseFloor: (j['noise'] as num?)?.toDouble() ?? 0,
        confirmed: j['confirmed'] as bool? ?? false,
        calibratedAt: j['at'] == null ? null : DateTime.parse(j['at'] as String),
      );
}
