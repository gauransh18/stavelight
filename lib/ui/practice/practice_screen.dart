import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../app/app_state.dart';
import '../../core/model/pitch.dart';
import '../../core/model/score.dart';
import '../../core/model/session.dart';
import '../../core/practice/input_event.dart';
import '../../core/practice/matcher.dart';
import '../../core/practice/practice_engine.dart';
import '../../core/practice/timeline.dart';
import '../../core/util/ids.dart';
import '../../services/mic_service.dart';
import '../render/falling_notes.dart';
import '../render/keyboard.dart';
import '../render/staff_view.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'practice_launcher.dart';

class PracticeScreen extends StatefulWidget {
  final String pieceId;
  final Score score;
  final PracticeRequest request;
  const PracticeScreen({super.key, required this.pieceId, required this.score, required this.request});
  @override
  State<PracticeScreen> createState() => _PracticeScreenState();
}

class _FrameNotifier extends ChangeNotifier {
  void tick() => notifyListeners();
}

class _PracticeScreenState extends State<PracticeScreen> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AppState _app;
  late PracticeEngine _engine;
  late final Ticker _ticker;
  final _frame = _FrameNotifier();
  final DateTime _startedAt = DateTime.now();
  final List<StreamSubscription<dynamic>> _subs = [];
  late PracticeDisplay _display = widget.request.display;
  Duration _lastTick = Duration.zero;

  final Set<int> _held = {};
  final Map<int, DateTime> _wrong = {};
  final Map<int, DateTime> _uncertainKeys = {};
  PracticeFeedback? _feedback;
  DateTime _feedbackAt = DateTime(2000);
  EngineState _lastState = EngineState.idle;
  int _lastMeasure = -1;
  bool _midiLost = false;
  bool _finished = false;
  String? _micProblem;

  InputKind get _input => widget.request.input;

  KeyLayout _layout(double w) {
    final lo = (_engine.timeline.notes.isEmpty ? 60 : _engine.timeline.notes.map((n) => n.midi).reduce((a, b) => a < b ? a : b));
    final hi = (_engine.timeline.notes.isEmpty ? 72 : _engine.timeline.notes.map((n) => n.midi).reduce((a, b) => a > b ? a : b));
    final cached = _layoutCache;
    if (cached != null && cached.$1 == w && cached.$2 == lo && cached.$3 == hi) return cached.$4;
    final l = KeyLayout.forNotes([lo, hi], w);
    _layoutCache = (w, lo, hi, l);
    return l;
  }

  (double, int, int, KeyLayout)? _layoutCache;
  PracticeConfig get _cfg => _engine.config;

  @override
  void initState() {
    super.initState();
    _app = context.read<AppState>();
    WidgetsBinding.instance.addObserver(this);
    final cfg = widget.request.config;
    final timeline = PracticeTimeline.build(widget.score, transpose: cfg.transpose, hands: cfg.hands);
    _engine = PracticeEngine(timeline, cfg, input: _input, sound: _app.audio)..onFeedback = _onFeedback;
    if (widget.request.startMeasure > 0 && !cfg.loop) _engine.seekMeasure(widget.request.startMeasure);
    _ticker = createTicker(_onTick)..start();
    _app.audio.init();
    _attachInput();
    WakelockPlus.enable().catchError((_) {});
  }

  Future<void> _attachInput() async {
    switch (_input) {
      case InputKind.midi:
        _subs.add(_app.midi.notes.listen(_onInputNote));
        _subs.add(_app.midi.pedal.listen(_engine.handlePedal));
        _app.midi.addListener(_onMidiChanged);
      case InputKind.mic:
        final mic = _app.mic..profile = _app.micProfile;
        _subs.add(mic.notes.listen(_onInputNote));
        _subs.add(mic.uncertain.listen((e) {
          _engine.handleUncertain(e);
        }));
        final ok = await mic.start();
        if (!ok && mounted) {
          setState(() => _micProblem = mic.status == MicStatus.denied
              ? 'Microphone access is off, so nothing will be scored. Allow it in Settings or connect a MIDI keyboard.'
              : 'The microphone could not start (${mic.error ?? 'unknown error'}).');
        }
      case InputKind.none:
        break;
    }
  }

  void _onMidiChanged() {
    if (_app.midi.connected == null && !_midiLost) {
      _engine.pause();
      setState(() => _midiLost = true);
    } else if (_app.midi.connected != null && _midiLost) {
      setState(() => _midiLost = false);
    }
  }

  void _onInputNote(InputNoteEvent e) {
    if (e.on) {
      _held.add(e.midi);
    } else {
      _held.remove(e.midi);
    }
    _engine.handleNote(e);
    _frame.tick();
  }

  void _onFeedback(PracticeFeedback f) {
    final now = DateTime.now();
    if (f.midi != null) {
      if (f.kind == FeedbackKind.wrong || f.kind == FeedbackKind.octaveHigh || f.kind == FeedbackKind.octaveLow || f.kind == FeedbackKind.extra) {
        _wrong[f.midi!] = now;
      } else if (f.kind == FeedbackKind.uncertain) {
        _uncertainKeys[f.midi!] = now;
      }
    }
    // Misses are reported at the end of the window; don't let them overwrite fresher feedback.
    if (f.kind == FeedbackKind.notHeard && now.difference(_feedbackAt).inMilliseconds < 400) return;
    _feedback = f;
    _feedbackAt = now;
    final s = _app.settings;
    final negative = !f.isPositive && !f.isNeutral && f.kind != FeedbackKind.notHeard;
    if (s.haptics && negative) HapticFeedback.lightImpact();
    if (s.audioCues && negative) {
      _app.audio.noteOn(33, 50);
      Future<void>.delayed(const Duration(milliseconds: 120), () => _app.audio.noteOff(33));
    }
  }

  void _onTick(Duration elapsed) {
    final dt = (elapsed - _lastTick).inMicroseconds / 1e6;
    _lastTick = elapsed;
    if (dt > 0 && dt < 0.25) _engine.tick(dt);
    _frame.tick();
    final m = _engine.currentMeasure;
    if (_engine.state != _lastState || m != _lastMeasure || DateTime.now().difference(_feedbackAt).inMilliseconds < 1200) {
      _lastState = _engine.state;
      _lastMeasure = m;
      if (mounted) setState(() {});
    }
    if (_engine.state == EngineState.finished && !_finished) {
      _finished = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _finish());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive || state == AppLifecycleState.hidden) {
      _engine.pause();
      _saveResume();
      if (_input == InputKind.mic) _app.mic.stop();
    } else if (state == AppLifecycleState.resumed && _input == InputKind.mic && _micProblem == null) {
      _app.mic.start();
    }
  }

  Future<void> _saveResume() async {
    final p = _app.library.byId(widget.pieceId);
    if (p == null) return;
    p.resumeMeasure = _engine.currentMeasure;
    await _app.library.update(p);
  }

  PracticeSession _session() => _engine.summarize(id: newId('s'), pieceId: widget.pieceId, startedAt: _startedAt);

  Future<void> _finish() async {
    _engine.pause();
    final s = _session();
    final atEnd = _engine.state == EngineState.finished;
    await _app.library.recordSession(s,
        measureCount: widget.score.measures.length, resumeMeasure: atEnd ? 0 : _engine.currentMeasure);
    _app.libraryChanged();
    if (mounted) Navigator.of(context).pop(s);
  }

  Future<void> _exit() async {
    final wasRunning = _engine.isRunning;
    _engine.pause();
    if (_engine.realElapsed < 5) {
      await _saveResume();
      if (mounted) Navigator.of(context).pop();
      return;
    }
    final choice = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('End this session?'),
        content: Text('You practiced for ${formatDuration(_engine.realElapsed.round())}. Your place is saved either way.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, 'discard'), child: const Text('Discard')),
          TextButton(onPressed: () => Navigator.pop(c, 'keep'), child: const Text('Keep practicing')),
          FilledButton(onPressed: () => Navigator.pop(c, 'end'), child: const Text('See summary')),
        ],
      ),
    );
    if (!mounted) return;
    switch (choice) {
      case 'end':
        _finished = true;
        await _finish();
      case 'discard':
        await _saveResume();
        if (mounted) Navigator.of(context).pop();
      default:
        if (wasRunning) _engine.resume();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    for (final s in _subs) {
      s.cancel();
    }
    _app.midi.removeListener(_onMidiChanged);
    if (_input == InputKind.mic) _app.mic.stop();
    _app.audio.allOff();
    WakelockPlus.disable().catchError((_) {});
    _frame.dispose();
    super.dispose();
  }

  // ---- Build -----------------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppState>().settings;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _exit();
      },
      child: Scaffold(
        body: SafeArea(
          child: LayoutBuilder(builder: (context, c) {
            final landscape = c.maxWidth > c.maxHeight;
            final kbHeight = (landscape ? c.maxHeight * 0.24 : c.maxHeight * 0.17).clamp(70.0, 180.0);
            return Column(children: [
              _topBar(landscape),
              if (_midiLost)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: InfoBanner('MIDI keyboard disconnected. Practice is paused — reconnect it, then press play.', icon: Icons.link_off, color: SlColors.warn),
                ),
              if (_micProblem != null)
                Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: InfoBanner(_micProblem!, icon: Icons.mic_off, color: SlColors.warn)),
              Expanded(child: Stack(children: [
                Positioned.fill(child: _display == PracticeDisplay.falling ? _falling(settings) : _sheet(settings)),
                _overlays(),
              ])),
              SizedBox(height: kbHeight, child: _keyboard(settings)),
            ]);
          }),
        ),
      ),
    );
  }

  Widget _falling(dynamic settings) {
    final s = _app.settings;
    return CustomPaint(
      painter: FallingNotesPainter(
        repaint: _frame,
        timeline: _engine.timeline,
        position: () => _engine.position,
        layoutFor: _layout,
        results: _engine.matcher.results,
        noteNames: s.noteNames,
        fingers: s.fingerNumbers,
        pedalLane: s.pedalLane,
        effects: s.visualEffects,
        highContrast: s.highContrast,
        brightness: Theme.of(context).brightness,
        loopStart: _cfg.loop ? _engine.rangeStart : null,
        loopEnd: _cfg.loop ? _engine.rangeEnd : null,
      ),
      child: const SizedBox.expand(),
    );
  }

  Widget _sheet(dynamic settings) {
    final s = _app.settings;
    return AnimatedBuilder(
      animation: _frame,
      builder: (_, _) => StaffView(
        score: widget.score,
        cursorTick: _engine.timeline.tempoMap.tickAt(_engine.position),
        highlightMeasure: _engine.currentMeasure,
        outcomes: {for (final e in _engine.matcher.results.entries) e.key: e.value.outcome},
        showPedal: s.pedalLane,
        noteNames: s.noteNames,
        showFingers: s.fingerNumbers,
        transpose: _cfg.transpose,
        scale: 1.15,
      ),
    );
  }

  Map<int, KeyState> _keyStates() {
    final out = <int, KeyState>{};
    final pos = _engine.position;
    final waiting = _engine.waitingFor;
    final soon = 0.12 * _cfg.tempoFactor;
    for (final n in _engine.timeline.notes) {
      if (n.start > pos + soon) break;
      final inWindow = waiting != null ? waiting.notes.contains(n) : (n.start >= pos - 0.05 && n.start <= pos + soon) || (n.start <= pos && n.end > pos && !n.active);
      if (!inWindow) continue;
      if (n.active) {
        out[n.midi] = KeyState(KeyMark.target, hand: n.hand);
      } else if (_cfg.playOtherHand) {
        out[n.midi] = KeyState(KeyMark.target, hand: n.hand);
      }
    }
    final now = DateTime.now();
    _wrong.removeWhere((_, t) => now.difference(t).inMilliseconds > 600);
    _uncertainKeys.removeWhere((_, t) => now.difference(t).inMilliseconds > 600);
    for (final m in _held) {
      final hand = _engine.timeline.notes.firstWhere((n) => n.midi == m && (n.start - pos).abs() < 1.5,
          orElse: () => ExpectedNote(noteId: '', midi: m, writtenMidi: m, hand: Hand.unassigned, startTick: 0, holdTicks: 0, start: 0, holdSec: 0, soundEnd: 0, measure: 0, finger: null, confidence: 1, verified: true, active: true)).hand;
      out[m] = KeyState(_wrong.containsKey(m) ? KeyMark.wrong : _uncertainKeys.containsKey(m) ? KeyMark.uncertain : KeyMark.played, hand: hand);
    }
    if (_input == InputKind.mic) {
      final cur = _app.mic.currentNote;
      if (cur != null && !out.containsKey(cur)) out[cur] = const KeyState(KeyMark.played);
    }
    return out;
  }

  Widget _keyboard(dynamic settings) {
    final s = _app.settings;
    return AnimatedBuilder(
      animation: _frame,
      builder: (_, _) => Row(children: [
        SizedBox(
          width: kPedalLaneWidth,
          child: _input == InputKind.midi
              ? Tooltip(
                  message: 'Sustain pedal from your keyboard',
                  child: Center(
                    child: Icon(Icons.keyboard_double_arrow_down,
                        color: _app.midi.sustainDown ? SlColors.brass : Theme.of(context).disabledColor, semanticLabel: _app.midi.sustainDown ? 'Pedal down' : 'Pedal up'),
                  ),
                )
              : const SizedBox.shrink(),
        ),
        Expanded(
          child: PianoKeyboard(
            layoutFor: _layout,
            states: _keyStates(),
            labels: s.noteNames,
            octaveLabels: s.octaveLabels,
            highContrast: s.highContrast,
          ),
        ),
      ]),
    );
  }

  Widget _overlays() {
    final children = <Widget>[];
    if (_engine.state == EngineState.countIn) {
      children.add(Center(
        child: Semantics(
          liveRegion: true,
          label: 'Count in ${_engine.countInBeatsLeft + 1}',
          child: Container(
            width: 120,
            height: 120,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.9), shape: BoxShape.circle),
            child: Text('${(_engine.countInBeatsLeft + 1).clamp(1, _cfg.countInBeats)}',
                style: const TextStyle(fontSize: 56, color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ),
      ));
    }
    final fresh = DateTime.now().difference(_feedbackAt).inMilliseconds < 1100;
    if (_feedback != null && fresh && _input != InputKind.none) {
      children.add(Positioned(top: 10, left: 0, right: 0, child: Center(child: _FeedbackChip(_feedback!))));
    }
    if (_engine.state == EngineState.waiting && _engine.waitingFor != null) {
      final names = _engine.waitingFor!.notes.map((n) => Pitch.name(n.midi)).join(' + ');
      children.add(Positioned(
        bottom: 12,
        left: 12,
        right: 12,
        child: Center(
          child: Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.hourglass_top, size: 20),
                const SizedBox(width: 8),
                Flexible(child: Text('Play $names', style: Theme.of(context).textTheme.titleMedium)),
                if (_engine.canSkip) ...[
                  const SizedBox(width: 12),
                  FilledButton.tonalIcon(onPressed: _engine.skip, icon: const Icon(Icons.skip_next), label: const Text('Skip')),
                ],
              ]),
            ),
          ),
        ),
      ));
    }
    if (_engine.state == EngineState.idle || _engine.state == EngineState.paused) {
      children.add(Center(
        child: FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: const Size(180, 64)),
          onPressed: _togglePlay,
          icon: const Icon(Icons.play_arrow, size: 32),
          label: Text(_engine.state == EngineState.paused ? 'Resume' : 'Start', style: const TextStyle(fontSize: 20)),
        ),
      ));
    }
    return Stack(children: children);
  }

  void _togglePlay() {
    if (_engine.isRunning) {
      _engine.pause();
      _saveResume();
    } else {
      if (_midiLost) return;
      _engine.start();
    }
    setState(() {});
  }

  Widget _topBar(bool landscape) {
    final t = Theme.of(context).textTheme;
    final measureCount = _engine.timeline.measureCount;
    final modeLabel = switch (_cfg.mode) {
      PracticeMode.wait => 'Wait mode',
      PracticeMode.follow => 'Follow along',
      PracticeMode.freePlay => 'Free play',
    };
    final title = Expanded(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(widget.score.title, style: t.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
        Text(
          [
            'Measure ${_engine.currentMeasure + 1} of $measureCount',
            modeLabel,
            if (_cfg.hands != HandsSelection.both) _cfg.hands == HandsSelection.right ? 'Right hand' : 'Left hand',
            if (_cfg.transpose != 0) 'Transposed ${_cfg.transpose > 0 ? '+' : ''}${_cfg.transpose}',
            if (_cfg.loop) 'Loop ${_cfg.loopStart! + 1}–${_cfg.loopEnd! + 1}',
          ].join(' · '),
          style: t.bodySmall,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ]),
    );
    final controls = Row(mainAxisSize: MainAxisSize.min, children: [
      IconButton(tooltip: 'Previous measure', onPressed: () => setState(_engine.previousMeasure), icon: const Icon(Icons.skip_previous)),
      IconButton.filled(
        tooltip: _engine.isRunning ? 'Pause' : 'Play',
        iconSize: 30,
        onPressed: _togglePlay,
        icon: Icon(_engine.isRunning ? Icons.pause : Icons.play_arrow),
      ),
      IconButton(tooltip: 'Next measure', onPressed: () => setState(_engine.nextMeasure), icon: const Icon(Icons.skip_next)),
      IconButton(tooltip: 'Restart', onPressed: () => setState(_engine.restart), icon: const Icon(Icons.replay)),
      TextButton(
        onPressed: _tempoDialog,
        child: Text('${(_cfg.tempoFactor * 100).round()}%', semanticsLabel: 'Tempo ${(_cfg.tempoFactor * 100).round()} percent'),
      ),
      IconButton(
        tooltip: _cfg.metronome ? 'Metronome on' : 'Metronome off',
        isSelected: _cfg.metronome,
        onPressed: () => setState(() => _cfg.metronome = !_cfg.metronome),
        icon: const Icon(Icons.timer_outlined),
        selectedIcon: const Icon(Icons.timer),
      ),
      IconButton(
        tooltip: _cfg.loop ? 'Section loop on' : 'Loop a section',
        isSelected: _cfg.loop,
        onPressed: _loopDialog,
        icon: const Icon(Icons.repeat),
        selectedIcon: const Icon(Icons.repeat_on),
      ),
      IconButton(
        tooltip: _display == PracticeDisplay.falling ? 'Show sheet music' : 'Show falling notes',
        onPressed: () => setState(() => _display = _display == PracticeDisplay.falling ? PracticeDisplay.sheet : PracticeDisplay.falling),
        icon: Icon(_display == PracticeDisplay.falling ? Icons.queue_music : Icons.view_week_outlined),
      ),
      IconButton(tooltip: 'More options', onPressed: _moreSheet, icon: const Icon(Icons.tune)),
    ]);
    final chip = _InputChip(input: _input, app: _app);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 8, 4),
      child: landscape
          ? Row(children: [IconButton(tooltip: 'Leave practice', onPressed: _exit, icon: const Icon(Icons.close)), title, chip, const SizedBox(width: 8), controls])
          : Column(children: [
              Row(children: [IconButton(tooltip: 'Leave practice', onPressed: _exit, icon: const Icon(Icons.close)), title, chip]),
              SingleChildScrollView(scrollDirection: Axis.horizontal, child: controls),
            ]),
    );
  }

  Future<void> _tempoDialog() async {
    final base = widget.score.tempos.isEmpty ? 100.0 : widget.score.tempos.first.bpm;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
                Text('Tempo', style: Theme.of(c).textTheme.titleMedium),
                const Spacer(),
                Text('${(_cfg.tempoFactor * 100).round()}% · ${(base * _cfg.tempoFactor).round()} BPM'),
                const HelpButton('tempo'),
              ]),
              Slider(
                value: _cfg.tempoFactor,
                min: 0.25,
                max: 1.5,
                divisions: 25,
                label: '${(_cfg.tempoFactor * 100).round()}%',
                onChanged: (v) => set(() => _engine.setTempo(v)),
              ),
              Wrap(spacing: 8, children: [
                for (final p in [0.5, 0.75, 1.0])
                  ActionChip(label: Text('${(p * 100).round()}%'), onPressed: () => set(() => _engine.setTempo(p))),
              ]),
            ]),
          ),
        ),
      ),
    );
    setState(() {});
  }

  Future<void> _loopDialog() async {
    final count = _engine.timeline.measureCount;
    if (count < 1) return;
    var range = RangeValues(
      (_cfg.loopStart ?? _engine.currentMeasure).toDouble(),
      (_cfg.loopEnd ?? (_engine.currentMeasure + 1).clamp(0, count - 1)).toDouble(),
    );
    final result = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Row(children: [Text('Section loop', style: Theme.of(c).textTheme.titleMedium), const Spacer(), const HelpButton('loop')]),
              Text('Measures ${range.start.round() + 1}–${range.end.round() + 1}'),
              if (count > 1)
                RangeSlider(
                  values: range,
                  min: 0,
                  max: (count - 1).toDouble(),
                  divisions: count - 1,
                  labels: RangeLabels('${range.start.round() + 1}', '${range.end.round() + 1}'),
                  onChanged: (v) => set(() => range = v),
                ),
              Row(children: [
                if (_cfg.loop) TextButton(onPressed: () => Navigator.pop(c, 'off'), child: const Text('Turn off')),
                const Spacer(),
                FilledButton(onPressed: () => Navigator.pop(c, 'on'), child: const Text('Loop these measures')),
              ]),
            ]),
          ),
        ),
      ),
    );
    if (result == 'on') {
      _engine.setLoop(range.start.round(), range.end.round());
    } else if (result == 'off') {
      _engine.setLoop(null, null, enabled: false);
    }
    setState(() {});
  }

  Future<void> _moreSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (c) => StatefulBuilder(builder: (c, set) {
        final s = _app.settings;
        void toggle(void Function() f) {
          _app.updateSettings((_) => f());
          set(() {});
          setState(() {});
        }

        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [Text('Hands', style: Theme.of(c).textTheme.titleMedium), const HelpButton('hands')]),
              SegmentedButton<HandsSelection>(
                segments: const [
                  ButtonSegment(value: HandsSelection.both, label: Text('Both')),
                  ButtonSegment(value: HandsSelection.right, label: Text('Right')),
                  ButtonSegment(value: HandsSelection.left, label: Text('Left')),
                ],
                selected: {_cfg.hands},
                onSelectionChanged: (v) => set(() => _engine.setHands(v.first)),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Play the other hand'),
                value: _cfg.playOtherHand,
                onChanged: (v) => set(() => _cfg.playOtherHand = v),
              ),
              Row(children: [Text('Transpose', style: Theme.of(c).textTheme.titleMedium), const HelpButton('transpose')]),
              Row(children: [
                IconButton.outlined(tooltip: 'Down a semitone', onPressed: () => set(() => _engine.setTranspose(_cfg.transpose - 1)), icon: const Icon(Icons.remove)),
                Expanded(child: Text(_cfg.transpose == 0 ? 'As written' : '${_cfg.transpose > 0 ? '+' : ''}${_cfg.transpose} semitones', textAlign: TextAlign.center)),
                IconButton.outlined(tooltip: 'Up a semitone', onPressed: () => set(() => _engine.setTranspose(_cfg.transpose + 1)), icon: const Icon(Icons.add)),
              ]),
              const Divider(height: 24),
              SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Note names'), value: s.noteNames, onChanged: (v) => toggle(() => s.noteNames = v)),
              SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Octave numbers on keys'), value: s.octaveLabels, onChanged: (v) => toggle(() => s.octaveLabels = v)),
              SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Finger numbers (if in the score)'), value: s.fingerNumbers, onChanged: (v) => toggle(() => s.fingerNumbers = v)),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Pedal lane'),
                secondary: const HelpButton('pedal'),
                value: s.pedalLane,
                onChanged: (v) => toggle(() => s.pedalLane = v),
              ),
              SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Visual effects'), value: s.visualEffects, onChanged: (v) => toggle(() => s.visualEffects = v)),
              SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Accent first beat'), value: _cfg.accentDownbeat, onChanged: (v) => set(() => _cfg.accentDownbeat = v)),
              Row(children: [const Expanded(child: Text('Playback volume')), SizedBox(width: 180, child: Slider(value: s.playbackVolume, onChanged: (v) => toggle(() => s.playbackVolume = v)))]),
              Row(children: [const Expanded(child: Text('Metronome volume')), SizedBox(width: 180, child: Slider(value: s.metronomeVolume, onChanged: (v) => toggle(() => s.metronomeVolume = v)))]),
              const Divider(height: 24),
              TextButton.icon(onPressed: () => showHelp(c, 'duration'), icon: const Icon(Icons.help_outline), label: const Text('Bars, tails and the pedal lane')),
            ]),
          ),
        );
      }),
    );
    setState(() {});
  }
}

class _FeedbackChip extends StatelessWidget {
  final PracticeFeedback f;
  const _FeedbackChip(this.f);
  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (f.kind) {
      FeedbackKind.correct => (Icons.check_circle, SlColors.good),
      FeedbackKind.early => (Icons.fast_rewind, SlColors.warn),
      FeedbackKind.late => (Icons.fast_forward, SlColors.warn),
      FeedbackKind.octaveHigh => (Icons.arrow_upward, SlColors.bad),
      FeedbackKind.octaveLow => (Icons.arrow_downward, SlColors.bad),
      FeedbackKind.wrong || FeedbackKind.extra => (Icons.close, SlColors.bad),
      FeedbackKind.releasedEarly => (Icons.timelapse, SlColors.warn),
      FeedbackKind.notHeard => (Icons.hearing_disabled, SlColors.unsure),
      FeedbackKind.uncertain => (Icons.help_outline, SlColors.unsure),
      FeedbackKind.noisy => (Icons.graphic_eq, SlColors.unsure),
    };
    final text = f.midi != null && f.kind != FeedbackKind.correct ? '${f.label} · ${Pitch.name(f.midi!)}' : f.label;
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(20)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, color: Colors.white, size: 20),
          const SizedBox(width: 6),
          Text(text, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }
}

class _InputChip extends StatelessWidget {
  final InputKind input;
  final AppState app;
  const _InputChip({required this.input, required this.app});
  @override
  Widget build(BuildContext context) {
    return switch (input) {
      InputKind.midi => Chip(
          avatar: const Icon(Icons.cable, size: 18),
          label: Text(app.midi.connected?.name ?? 'MIDI disconnected', overflow: TextOverflow.ellipsis),
          visualDensity: VisualDensity.compact,
        ),
      InputKind.mic => ListenableBuilder(
          listenable: app.mic,
          builder: (c, _) {
            final level = (app.mic.level * 8).clamp(0.0, 1.0);
            return Tooltip(
              message: 'Microphone: one note at a time. Unclear sounds are not counted as mistakes.',
              child: Chip(
                avatar: const Icon(Icons.mic, size: 18),
                label: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Text('Mic'),
                  const SizedBox(width: 6),
                  SizedBox(width: 36, child: LinearProgressIndicator(value: level, minHeight: 5, borderRadius: BorderRadius.circular(3))),
                ]),
                visualDensity: VisualDensity.compact,
              ),
            );
          },
        ),
      InputKind.none => const Chip(avatar: Icon(Icons.hearing_disabled_outlined, size: 18), label: Text('Not listening'), visualDensity: VisualDensity.compact),
    };
  }
}
