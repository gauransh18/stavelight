import 'package:flutter_test/flutter_test.dart';
import 'package:stavelight/core/edit/score_editor.dart';
import 'package:stavelight/core/model/pitch.dart';
import 'package:stavelight/core/model/score.dart';

void main() {
  test('appendMeasure continues numbering and meter, and is one undo step', () {
    final s = Score(title: 't', origin: ScoreOrigin.manual, measures: [
      Measure(index: 0, startTick: 0, lengthTicks: 1440, number: '1', time: const TimeSignature(3, 4), key: const KeySignature(-1)),
    ]);
    final e = ScoreEditor(s);
    e.appendMeasure();
    final m = e.score.measures.last;
    expect(e.score.measures.length, 2);
    expect((m.number, m.startTick, m.lengthTicks, m.time, m.key), ('2', 1440, 1440, const TimeSignature(3, 4), const KeySignature(-1)));
    e.undo();
    expect(e.score.measures.length, 1);
  });

  test('appendMeasure on an empty score starts a 4/4 bar at tick 0', () {
    final e = ScoreEditor(Score(title: 't', origin: ScoreOrigin.manual));
    e.appendMeasure();
    expect(e.score.measures.single.startTick, 0);
    expect(e.score.measures.single.lengthTicks, 1920);
  });

  test('pedal edits are independent of notes', () {
    final e = ScoreEditor(Score(title: 't', origin: ScoreOrigin.manual, notes: [
      ScoreNote(id: 'n', midi: 60, startTick: 0, durationTicks: 720, dots: 1),
    ]));
    final id = e.addPedal(0, PedalType.down);
    e.movePedal(id, 240);
    expect(e.score.notes.single.durationTicks, 720);
    expect(e.score.pedals.single.tick, 240);
    expect(e.score.pedals.single.verified, isTrue);
  });
}
