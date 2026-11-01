import '../model/calibration.dart';
import '../model/session.dart';
import '../practice/input_event.dart';
import 'pitch_detector.dart';

/// Turns pitch frames into note on/off events, filtering transients and noise.
/// Monophonic: tracks one dominant pitch at a time.
class NoteTracker {
  CalibrationProfile profile;

  /// Frames a pitch must persist before it counts as a note.
  final int stableFrames;
  void Function(InputNoteEvent)? onNote;
  void Function(InputUncertainEvent)? onUncertain;

  int? _current;
  int? _candidate;
  int _candidateCount = 0;
  double _candidateClarity = 0;
  int _silentCount = 0;
  int _unclearCount = 0;
  double _envelopeMin = 1;
  double _lastRms = 0;

  NoteTracker(this.profile, {this.stableFrames = 2, this.onNote, this.onUncertain});

  int? get currentNote => _current;

  /// RMS gate derived from the measured noise floor and the sensitivity setting.
  double get gate {
    final s = profile.sensitivity.clamp(0.0, 1.0);
    final factor = 4.0 - 2.5 * s; // high sensitivity → lower multiplier
    final absMin = 0.012 - 0.009 * s;
    final g = profile.noiseFloor * factor;
    return g > absMin ? g : absMin;
  }

  double get _clarityMin => 0.85 - 0.15 * profile.sensitivity.clamp(0.0, 1.0);

  void reset() {
    _current = null;
    _candidate = null;
    _candidateCount = 0;
    _silentCount = 0;
    _unclearCount = 0;
  }

  void process(PitchFrame f) {
    final loud = f.rms >= gate;
    if (!loud) {
      _silentCount++;
      _unclearCount = 0;
      _candidate = null;
      _candidateCount = 0;
      if (_current != null && _silentCount >= 2) _off(f.time);
      _envelopeMin = f.rms;
      _lastRms = f.rms;
      return;
    }
    _silentCount = 0;
    final mf = f.midiFloat(profile.a4Hz);
    if (mf == null || f.clarity < _clarityMin) {
      _unclearCount++;
      if (_unclearCount == 3) onUncertain?.call(InputUncertainEvent(f.time, 'No clear pitch (noise or several notes)'));
      _lastRms = f.rms;
      return;
    }
    _unclearCount = 0;
    final raw = mf.round();
    final cents = (mf - raw).abs() * 100;
    final midi = profile.correct(raw);

    // Re-attack of the same note: strong energy jump after decay.
    final reattack = _current == midi && f.rms > _envelopeMin * 2.2 && f.rms > _lastRms * 1.6;
    if (f.rms < _envelopeMin) _envelopeMin = f.rms;

    if (midi == _candidate) {
      _candidateCount++;
      _candidateClarity = (_candidateClarity + f.clarity) / 2;
    } else {
      _candidate = midi;
      _candidateCount = 1;
      _candidateClarity = f.clarity;
    }

    if (reattack) {
      _off(f.time);
      _on(midi, f.time, _confidence(f.clarity, cents));
      _envelopeMin = f.rms;
    } else if (_candidateCount >= stableFrames && midi != _current) {
      if (_current != null) _off(f.time);
      _on(midi, f.time, _confidence(_candidateClarity, cents));
      _envelopeMin = f.rms;
    }
    _lastRms = f.rms;
  }

  double _confidence(double clarity, double cents) {
    final tuning = (1 - (cents / 50)).clamp(0.0, 1.0);
    return (0.7 * clarity + 0.3 * tuning).clamp(0.0, 1.0);
  }

  void _on(int midi, double t, double conf) {
    _current = midi;
    onNote?.call(InputNoteEvent(midi: midi, time: t, on: true, confidence: conf, source: InputKind.mic));
  }

  void _off(double t) {
    final m = _current;
    if (m == null) return;
    _current = null;
    onNote?.call(InputNoteEvent(midi: m, time: t, on: false, confidence: 1, source: InputKind.mic));
  }
}
