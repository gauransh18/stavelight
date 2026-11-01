import 'package:flutter_test/flutter_test.dart';
import 'package:stavelight/core/import/track_selection.dart';
import 'package:stavelight/core/model/score.dart';

ScoreNote _n(int midi, int track, {int start = 0, Hand hand = Hand.unassigned}) =>
    ScoreNote(id: 'n$midi$track', midi: midi, startTick: start, durationTicks: 480, track: track, hand: hand);

Score _score() => Score(
      title: 't',
      origin: ScoreOrigin.midi,
      notes: [_n(72, 0), _n(55, 0, start: 480), _n(40, 1), _n(36, 2)],
      rests: [ScoreRest(startTick: 960, durationTicks: 480)],
      pedals: [PedalEvent(id: 'p', tick: 0, type: PedalType.down, source: 'midi')],
      tempos: [TempoEvent(0, 90)],
      tracks: [
        TrackInfo(index: 0, name: 'A', noteCount: 2, lowest: 55, highest: 72),
        TrackInfo(index: 1, name: 'B', noteCount: 1, lowest: 40, highest: 40),
        TrackInfo(index: 2, name: 'Drums', noteCount: 1, lowest: 36, highest: 36),
      ],
    );

void main() {
  test('keeps selected tracks and splits unassigned notes by pitch', () {
    final src = _score();
    final tracks = [for (final t in src.tracks) TrackInfo.fromJson(t.toJson())];
    tracks[2].selected = false;
    final out = applyTrackSelection(src, tracks, split: 56);

    expect(out.notes.map((n) => (n.midi, n.hand, n.staff)),
        [(40, Hand.left, 2), (72, Hand.right, 1), (55, Hand.left, 2)]);
    expect(out.handSplit, 56);
    expect(out.tracks, hasLength(3));
    expect(out.tracks[2].selected, isFalse);
    expect(out.pedals, hasLength(1));
    expect(out.rests, hasLength(1));
    expect(out.tempos.single.bpm, 90);
    expect(src.notes, hasLength(4)); // source untouched
    expect(src.notes.first.hand, Hand.unassigned);
  });

  test('track hand overrides; existing note hands are kept when the track is unassigned', () {
    final src = _score()..notes.add(_n(80, 1, hand: Hand.left));
    final tracks = [for (final t in src.tracks) TrackInfo.fromJson(t.toJson())];
    tracks[0].hand = Hand.left;
    final out = applyTrackSelection(src, tracks);
    expect(out.notes.where((n) => n.track == 0).every((n) => n.hand == Hand.left && n.staff == 2), isTrue);
    expect(out.notes.firstWhere((n) => n.midi == 80).hand, Hand.left);
  });
}
