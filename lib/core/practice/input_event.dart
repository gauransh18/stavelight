import '../model/session.dart';

/// Input-agnostic note event fed to the matcher. Times are in seconds on the practice clock.
class InputNoteEvent {
  final int midi;
  final double time;
  final bool on;

  /// 1.0 for MIDI. Microphone confidence from pitch clarity and stability.
  final double confidence;
  final InputKind source;
  final int velocity;

  const InputNoteEvent({
    required this.midi,
    required this.time,
    required this.on,
    this.confidence = 1.0,
    this.source = InputKind.midi,
    this.velocity = 80,
  });

  @override
  String toString() => 'InputNoteEvent(${on ? 'on' : 'off'} $midi @${time.toStringAsFixed(3)} c=${confidence.toStringAsFixed(2)})';
}

/// Signal present but no reliable pitch (noise, chord, heavy sustain). Mic only.
class InputUncertainEvent {
  final double time;
  final String reason;
  const InputUncertainEvent(this.time, this.reason);
}

/// Sustain pedal change from a MIDI keyboard (CC64).
class InputPedalEvent {
  final double time;
  final bool down;
  const InputPedalEvent(this.time, this.down);
}
