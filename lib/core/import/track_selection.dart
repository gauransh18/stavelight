import '../model/score.dart';

/// Returns a copy of [source] keeping only notes from selected [tracks] (matched by [TrackInfo.index]).
///
/// Each note's hand comes from its track's [TrackInfo.hand]; if that is unassigned the note keeps its own hand,
/// and notes with no hand at all are split by pitch (>= [split] → right). Staff follows hand (right 1, left 2).
/// Pedals, tempos, measures and rests are kept.
Score applyTrackSelection(Score source, List<TrackInfo> tracks, {int split = 60}) {
  final out = source.copy();
  final byIndex = {for (final t in tracks) t.index: t};
  out.notes = out.notes.where((n) => byIndex[n.track]?.selected ?? false).toList();
  for (final n in out.notes) {
    final trackHand = byIndex[n.track]!.hand;
    if (trackHand != Hand.unassigned) {
      n.hand = trackHand;
    } else if (n.hand == Hand.unassigned) {
      n.hand = n.midi >= split ? Hand.right : Hand.left;
    }
    n.staff = n.hand == Hand.right ? 1 : 2;
  }
  out.tracks = [for (final t in tracks) TrackInfo.fromJson(t.toJson())];
  out.handSplit = split;
  final pedals = [...out.pedals];
  // normalize()'s sort is unstable; keep the source pedal order (same-tick up/down pairs).
  return out
    ..normalize()
    ..pedals = pedals;
}
