import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:stavelight/core/audio/note_tracker.dart';
import 'package:stavelight/core/audio/pitch_detector.dart';
import 'package:stavelight/core/audio/synth.dart';
import 'package:stavelight/core/model/calibration.dart';
import 'package:stavelight/core/model/pitch.dart';
import 'package:stavelight/core/model/session.dart';
import 'package:stavelight/core/practice/input_event.dart';

Float32List tone(double hz, int n, {int sr = 22050, double amp = 0.3, List<double> harmonics = const [1]}) {
  final out = Float32List(n);
  for (var i = 0; i < n; i++) {
    var s = 0.0;
    for (var k = 0; k < harmonics.length; k++) {
      s += harmonics[k] * math.sin(2 * math.pi * hz * (k + 1) * i / sr);
    }
    out[i] = amp * s;
  }
  return out;
}

void main() {
  final yin = YinDetector();

  test('YIN finds A4, middle C and a low bass note with piano-like harmonics', () {
    for (final midi in [69, 60, 36, 84]) {
      final f = yin.analyze(tone(Pitch.frequency(midi), 2048, harmonics: [1, 0.6, 0.4, 0.2]), 0);
      expect(f.hz, isNotNull, reason: 'midi $midi');
      expect(f.midiFloat(440)!.round(), midi, reason: 'midi $midi');
      expect(f.clarity, greaterThan(0.85));
    }
  });

  test('tuning reference shifts the detected note', () {
    final f = yin.analyze(tone(432, 2048), 0);
    expect(f.midiFloat(440)!.round(), 69);
    expect((f.midiFloat(432)! - 69).abs(), lessThan(0.05));
  });

  test('white noise yields low clarity or no pitch', () {
    final r = math.Random(1);
    final noise = Float32List.fromList(List.generate(2048, (_) => (r.nextDouble() * 2 - 1) * 0.3));
    final f = yin.analyze(noise, 0);
    expect(f.hz == null || f.clarity < 0.7, isTrue);
  });

  test('note tracker emits on/off with octave calibration applied and filters transients', () {
    final events = <InputNoteEvent>[];
    final profile = CalibrationProfile(key: 'mic', input: InputKind.mic, octaveOffset: 1, noiseFloor: 0.002);
    final tracker = NoteTracker(profile, onNote: events.add);
    final buf = FrameBuffer(2048, 1024);
    var t = 0.0;
    void feed(Float32List s) {
      for (final (frame, _) in buf.push(s)) {
        tracker.process(yin.analyze(frame, t));
        t += 1024 / 22050;
      }
    }

    feed(Float32List(4096)); // silence
    feed(tone(Pitch.frequency(57), 1024)); // ~46 ms blip: too short to count
    feed(Float32List(4096));
    feed(tone(Pitch.frequency(57), 11025, harmonics: [1, 0.5, 0.3])); // A3 for 0.5 s
    feed(Float32List(8192));
    expect(events.where((e) => e.on).length, 1);
    expect(events.first.midi, 69); // A3 + 1 octave calibration
    expect(events.first.source, InputKind.mic);
    expect(events.last.on, isFalse);
  });

  test('synth renders bounded audio and releases voices', () {
    final s = Synth(sampleRate: 22050);
    s.noteOn(60);
    s.click(accent: true);
    final a = s.render(2205);
    expect(a.any((v) => v.abs() > 1000), isTrue);
    s.noteOff(60);
    s.render(22050);
    expect(s.activeVoices, 0);
  });
}
