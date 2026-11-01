import 'package:flutter_test/flutter_test.dart';
import 'package:stavelight/core/model/session.dart';
import 'package:stavelight/core/practice/practice_engine.dart';
import 'package:stavelight/core/practice/suggestions.dart';

PracticeSession sess() => PracticeSession(id: 's', pieceId: 'p', startedAt: DateTime(2026), input: InputKind.midi);

void main() {
  test('low-quality input gives no performance conclusions', () {
    final s = sess()
      ..lowQuality = true
      ..missed = 10;
    final r = suggestNext(s, PracticeConfig(), 8);
    expect(r.config, isNull);
    expect(r.text, contains('can’t be judged'));
  });

  test('weak measure → slower loop in wait mode', () {
    final s = sess()
      ..correct = 10
      ..missed = 6
      ..perMeasure = {
        0: MeasureStat()..expected = 4..correct = 4,
        3: MeasureStat()..expected = 6..correct = 2..errors = 4,
      };
    final r = suggestNext(s, PracticeConfig(tempoFactor: 1), 8);
    expect(r.config!.loop, isTrue);
    expect(r.config!.loopStart, 3);
    expect(r.config!.loopEnd, 4);
    expect(r.config!.tempoFactor, closeTo(0.8, 1e-9));
    expect(r.config!.mode, PracticeMode.wait);
  });

  test('accurate at reduced tempo → suggest speeding up', () {
    final s = sess()..correct = 20;
    final r = suggestNext(s, PracticeConfig(tempoFactor: 0.7), 8);
    expect(r.config!.tempoFactor, closeTo(0.8, 1e-9));
  });
}
