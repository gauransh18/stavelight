import 'package:flutter/material.dart';

import '../../core/model/pitch.dart';
import '../../core/model/score.dart';
import '../widgets/common.dart';

/// Choose which tracks/parts to practice and which hand plays each one.
/// Returns the edited track list and the pitch split used for tracks set to "Split by pitch".
class TrackSelectScreen extends StatefulWidget {
  final Score score;
  const TrackSelectScreen({super.key, required this.score});
  @override
  State<TrackSelectScreen> createState() => _TrackSelectScreenState();
}

class _TrackSelectScreenState extends State<TrackSelectScreen> {
  late final List<TrackInfo> _tracks;
  int _split = 60;

  @override
  void initState() {
    super.initState();
    _tracks = [for (final t in widget.score.tracks) TrackInfo.fromJson(t.toJson())];
    if (_tracks.isEmpty) {
      final notes = widget.score.notes;
      _tracks.add(TrackInfo(
        index: 0,
        name: 'Piano',
        noteCount: notes.length,
        lowest: notes.isEmpty ? 60 : notes.map((n) => n.midi).reduce((a, b) => a < b ? a : b),
        highest: notes.isEmpty ? 60 : notes.map((n) => n.midi).reduce((a, b) => a > b ? a : b),
      ));
    }
    _split = widget.score.handSplit;
  }

  bool get _anySelected => _tracks.any((t) => t.selected);
  bool get _usesSplit => _tracks.any((t) => t.selected && t.hand == Hand.unassigned);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Parts & hands'), actions: [const HelpButton('hands')]),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.all(16), children: [
          Text(
            _tracks.length > 1
                ? 'This file has ${_tracks.length} parts. Choose what you want to practice and which hand plays it.'
                : 'Tell Stavelight which hand plays which notes. You can fix individual notes later in review.',
            style: t.bodyLarge,
          ),
          const SizedBox(height: 16),
          for (final tr in _tracks)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: tr.selected,
                      onChanged: (v) => setState(() => tr.selected = v ?? false),
                      title: Text(tr.name.isEmpty ? 'Part ${tr.index + 1}' : tr.name, style: t.titleMedium),
                      subtitle: Text('${tr.noteCount} notes · ${Pitch.name(tr.lowest)}–${Pitch.name(tr.highest)}'),
                    ),
                    if (tr.selected)
                      SegmentedButton<Hand>(
                        segments: const [
                          ButtonSegment(value: Hand.right, label: Text('Right'), icon: HandBadge(Hand.right, size: 18)),
                          ButtonSegment(value: Hand.left, label: Text('Left'), icon: HandBadge(Hand.left, size: 18)),
                          ButtonSegment(value: Hand.unassigned, label: Text('Split'), icon: Icon(Icons.call_split)),
                        ],
                        selected: {tr.hand},
                        onSelectionChanged: (s) => setState(() => tr.hand = s.first),
                      ),
                  ]),
                ),
              ),
            ),
          if (_usesSplit) ...[
            const SectionTitle('Split point'),
            Text('Notes at or above ${Pitch.name(_split)} go to the right hand; lower notes to the left.', style: t.bodyMedium),
            Slider(
              value: _split.toDouble(),
              min: 36,
              max: 84,
              divisions: 48,
              label: Pitch.name(_split),
              onChanged: (v) => setState(() => _split = v.round()),
            ),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _anySelected ? () => Navigator.pop(context, (_tracks, _split)) : null,
            child: const Text('Continue'),
          ),
          if (!_anySelected) const Padding(padding: EdgeInsets.only(top: 8), child: Text('Select at least one part.')),
        ]),
      ),
    );
  }
}
