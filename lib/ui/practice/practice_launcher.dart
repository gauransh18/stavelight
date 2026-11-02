import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/app_state.dart';
import '../../core/model/score.dart';
import '../../core/model/session.dart';
import '../../core/practice/practice_engine.dart';
import '../calibration/calibration_screen.dart';
import '../review/review_screen.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'practice_screen.dart';
import 'summary_screen.dart';

enum PracticeDisplay { falling, sheet }

class PracticeRequest {
  final PracticeConfig config;
  final InputKind input;
  final PracticeDisplay display;
  final int startMeasure;
  PracticeRequest(this.config, this.input, this.display, this.startMeasure);
}

/// Load a piece, let the user choose mode/settings, run practice, then show the summary.
Future<void> launchPractice(BuildContext context, String pieceId, {PracticeConfig? preset}) async {
  final app = context.read<AppState>();
  final score = await app.library.loadScore(pieceId);
  final piece = app.library.byId(pieceId);
  if (!context.mounted || piece == null) return;
  if (score == null || score.notes.isEmpty) {
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('No notes to practice yet'),
        content: const Text('This score has no notes. Open the review editor to add or correct them.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Close')),
          FilledButton(
            onPressed: () {
              Navigator.pop(c);
              Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ReviewScreen(pieceId: pieceId)));
            },
            child: const Text('Open review'),
          ),
        ],
      ),
    );
    return;
  }

  var current = preset;
  while (true) {
    if (!context.mounted) return;
    final req = await showModalBottomSheet<PracticeRequest>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (_) => PracticeSetupSheet(score: score, pieceId: pieceId, resumeMeasure: piece.resumeMeasure, preset: current),
    );
    if (req == null || !context.mounted) return;
    final session = await Navigator.of(context).push<PracticeSession>(MaterialPageRoute(
      builder: (_) => PracticeScreen(pieceId: pieceId, score: score, request: req),
    ));
    if (session == null || !context.mounted) return;
    final again = await Navigator.of(context).push<PracticeConfig>(MaterialPageRoute(
      builder: (_) => SummaryScreen(session: session, score: score, config: req.config),
    ));
    if (again == null) return;
    current = again;
  }
}

class PracticeSetupSheet extends StatefulWidget {
  final Score score;
  final String pieceId;
  final int resumeMeasure;
  final PracticeConfig? preset;
  const PracticeSetupSheet({super.key, required this.score, required this.pieceId, required this.resumeMeasure, this.preset});
  @override
  State<PracticeSetupSheet> createState() => _PracticeSetupSheetState();
}

class _PracticeSetupSheetState extends State<PracticeSetupSheet> {
  late PracticeConfig _c;
  late InputKind _input;
  PracticeDisplay _display = PracticeDisplay.falling;
  late RangeValues _range;
  bool _resume = false;

  int get _measures => widget.score.measures.isEmpty ? 1 : widget.score.measures.length;

  @override
  void initState() {
    super.initState();
    final app = context.read<AppState>();
    final s = app.settings;
    _c = widget.preset ??
        PracticeConfig(
          countInBeats: s.countInBeats,
          accentDownbeat: s.accentDownbeat,
          waitTimeout: s.waitTimeout,
        );
    _input = app.activeInput;
    _range = RangeValues((_c.loopStart ?? 0).toDouble(), (_c.loopEnd ?? _measures - 1).toDouble());
    _resume = widget.preset == null && widget.resumeMeasure > 0 && widget.resumeMeasure < _measures;
  }

  double get _baseBpm => widget.score.tempos.isEmpty ? 100 : widget.score.tempos.first.bpm;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final t = Theme.of(context).textTheme;
    final midiOk = app.midi.connected != null;
    final micCal = app.calibrations['mic']?.confirmed ?? false;
    final unverified = widget.score.uncertainCount;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.9,
      maxChildSize: 0.95,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        children: [
          Text(widget.score.title, style: t.headlineSmall),
          const SizedBox(height: 8),
          if (unverified > 0)
            InfoBanner(
              '$unverified item(s) in this score are still unverified. Feedback on those notes may be wrong.',
              icon: Icons.help_outline,
              color: SlColors.warn,
              action: TextButton(
                onPressed: () {
                  Navigator.pop(context);
                  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ReviewScreen(pieceId: widget.pieceId)));
                },
                child: const Text('Review'),
              ),
            ),
          SectionTitle('Mode', trailing: HelpButton(_c.mode == PracticeMode.wait ? 'wait' : 'follow')),
          SegmentedButton<PracticeMode>(
            segments: const [
              ButtonSegment(value: PracticeMode.follow, label: Text('Follow along'), icon: Icon(Icons.play_circle_outline)),
              ButtonSegment(value: PracticeMode.wait, label: Text('Wait for me'), icon: Icon(Icons.pause_circle_outline)),
            ],
            selected: {_c.mode},
            onSelectionChanged: (s) => setState(() => _c.mode = s.first),
          ),
          SectionTitle('Hands', trailing: const HelpButton('hands')),
          SegmentedButton<HandsSelection>(
            segments: const [
              ButtonSegment(value: HandsSelection.both, label: Text('Both')),
              ButtonSegment(value: HandsSelection.right, label: Text('Right'), icon: HandBadge(Hand.right, size: 18)),
              ButtonSegment(value: HandsSelection.left, label: Text('Left'), icon: HandBadge(Hand.left, size: 18)),
            ],
            selected: {_c.hands},
            onSelectionChanged: (s) => setState(() => _c.hands = s.first),
          ),
          if (_c.hands != HandsSelection.both)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Play the other hand for me'),
              value: _c.playOtherHand,
              onChanged: (v) => setState(() => _c.playOtherHand = v),
            ),
          SectionTitle('Tempo', trailing: const HelpButton('tempo')),
          Row(children: [
            Expanded(
              child: Slider(
                value: _c.tempoFactor,
                min: 0.25,
                max: 1.5,
                divisions: 25,
                label: '${(_c.tempoFactor * 100).round()}%',
                onChanged: (v) => setState(() => _c.tempoFactor = v),
              ),
            ),
            SizedBox(width: 120, child: Text('${(_c.tempoFactor * 100).round()}% · ${(_baseBpm * _c.tempoFactor).round()} BPM', textAlign: TextAlign.end)),
          ]),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Metronome'),
            value: _c.metronome,
            onChanged: (v) => setState(() => _c.metronome = v),
          ),
          Row(children: [
            const Expanded(child: Text('Count-in')),
            DropdownButton<int>(
              value: _c.countInBeats,
              items: [for (final b in [0, 2, 3, 4, 6, 8]) DropdownMenuItem(value: b, child: Text(b == 0 ? 'Off' : '$b beats'))],
              onChanged: (v) => setState(() => _c.countInBeats = v ?? 4),
            ),
          ]),
          SectionTitle('Section', trailing: const HelpButton('loop')),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Practice a section'),
            subtitle: Text(_c.loop ? 'Measures ${_range.start.round() + 1}–${_range.end.round() + 1}, repeating' : 'Whole piece'),
            value: _c.loop,
            onChanged: _measures < 2 ? null : (v) => setState(() => _c.loop = v),
          ),
          if (_c.loop && _measures >= 2) ...[
            RangeSlider(
              values: _range,
              min: 0,
              max: (_measures - 1).toDouble(),
              divisions: _measures - 1,
              labels: RangeLabels('${_range.start.round() + 1}', '${_range.end.round() + 1}'),
              onChanged: (v) => setState(() => _range = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Count-in before each repeat'),
              value: _c.countInEachLoop,
              onChanged: (v) => setState(() => _c.countInEachLoop = v),
            ),
          ],
          if (!_c.loop && widget.resumeMeasure > 0 && widget.resumeMeasure < _measures)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('Resume from measure ${widget.resumeMeasure + 1}'),
              value: _resume,
              onChanged: (v) => setState(() => _resume = v ?? false),
            ),
          SectionTitle('Transpose', trailing: const HelpButton('transpose')),
          Row(children: [
            IconButton.outlined(tooltip: 'Down a semitone', onPressed: _c.transpose > -12 ? () => setState(() => _c.transpose--) : null, icon: const Icon(Icons.remove)),
            Expanded(child: Text(_c.transpose == 0 ? 'As written' : '${_c.transpose > 0 ? '+' : ''}${_c.transpose} semitones', textAlign: TextAlign.center)),
            IconButton.outlined(tooltip: 'Up a semitone', onPressed: _c.transpose < 12 ? () => setState(() => _c.transpose++) : null, icon: const Icon(Icons.add)),
          ]),
          const SectionTitle('Display'),
          SegmentedButton<PracticeDisplay>(
            segments: const [
              ButtonSegment(value: PracticeDisplay.falling, label: Text('Falling notes'), icon: Icon(Icons.view_week_outlined)),
              ButtonSegment(value: PracticeDisplay.sheet, label: Text('Sheet music'), icon: Icon(Icons.queue_music)),
            ],
            selected: {_display},
            onSelectionChanged: (s) => setState(() => _display = s.first),
          ),
          SectionTitle('Listening with', trailing: HelpButton(_input == InputKind.mic ? 'mic' : 'midi')),
          // A vertical list keeps long labels whole at large text sizes.
          RadioGroup<InputKind>(
            groupValue: _input,
            onChanged: (v) {
              if (v != null) setState(() => _input = v);
            },
            child: Column(children: [
              RadioListTile<InputKind>(
                value: InputKind.midi,
                enabled: midiOk,
                contentPadding: EdgeInsets.zero,
                secondary: const Icon(Icons.cable),
                title: const Text('MIDI keyboard'),
                subtitle: Text(midiOk ? 'Connected: ${app.midi.connected?.name}. Precise pitch, timing, key release and pedal.' : 'No keyboard connected.'),
              ),
              RadioListTile<InputKind>(
                value: InputKind.mic,
                contentPadding: EdgeInsets.zero,
                secondary: const Icon(Icons.mic_none),
                title: const Text('Microphone'),
                subtitle: Text(micCal
                    ? 'Calibrated. One note at a time is detected; unclear sounds are never counted as mistakes.'
                    : 'Not calibrated yet. Calibrating checks the octave so right notes aren’t marked wrong.'),
              ),
              const RadioListTile<InputKind>(
                value: InputKind.none,
                contentPadding: EdgeInsets.zero,
                secondary: Icon(Icons.hearing_disabled_outlined),
                title: Text('Just play along'),
                subtitle: Text('The score plays and nothing is scored.'),
              ),
            ]),
          ),
          if (!midiOk || (_input == InputKind.mic && !micCal))
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => CalibrationScreen(initialInput: _input == InputKind.mic ? InputKind.mic : InputKind.midi))),
                icon: const Icon(Icons.tune),
                label: Text(_input == InputKind.mic ? 'Calibrate microphone' : 'Connect a MIDI keyboard'),
              ),
            ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: () {
              _c.loopStart = _c.loop ? _range.start.round() : null;
              _c.loopEnd = _c.loop ? _range.end.round() : null;
              final start = _c.loop ? _range.start.round() : (_resume ? widget.resumeMeasure : 0);
              final input = _input == InputKind.midi && !midiOk ? InputKind.none : _input;
              _c.demo = false;
              app.updateSettings((s) {
                if (input == InputKind.mic) s.preferredInput = 'mic';
                if (input == InputKind.midi) s.preferredInput = 'midi';
              });
              Navigator.pop(context, PracticeRequest(_c, input, _display, start));
            },
            icon: const Icon(Icons.play_arrow),
            label: const Text('Start practicing'),
          ),
        ],
      ),
    );
  }
}
