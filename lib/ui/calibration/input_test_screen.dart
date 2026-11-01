import 'dart:async';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart' show openAppSettings;
import 'package:provider/provider.dart';

import '../../app/app_state.dart';
import '../../core/model/pitch.dart';
import '../../core/model/session.dart';
import '../../core/practice/input_event.dart';
import '../../services/mic_service.dart';
import '../render/keyboard.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'calibration_screen.dart';

/// Keyboard window that follows played notes. It stays still while you play inside it and shifts
/// by the smallest amount needed when a note falls outside, so alternating notes never make it jump
/// back and forth.
abstract final class KeyWindow {
  static const span = 36; // three octaves
  static const lowest = 21; // A0
  static const highest = 108; // C8

  static (int, int) follow(int lo, int hi, int note, {int margin = 2}) {
    if (note < lo + margin) {
      final d = lo + margin - note;
      lo -= d;
      hi -= d;
    } else if (note > hi - margin) {
      final d = note - (hi - margin);
      lo += d;
      hi += d;
    }
    if (lo < lowest) {
      hi += lowest - lo;
      lo = lowest;
    }
    if (hi > highest) {
      lo -= hi - highest;
      hi = highest;
    }
    return (lo, hi);
  }
}

class _Heard {
  final int midi;
  final Duration at;
  final double? confidence; // null = exact (MIDI)
  const _Heard(this.midi, this.at, this.confidence);
  bool get uncertain => confidence != null && confidence! < CalibrationMath.minConfidence;
}

/// Free play / input diagnostics: shows what the active input hears. Nothing is scored.
class InputTestScreen extends StatefulWidget {
  final bool diagnostics;
  const InputTestScreen({super.key, this.diagnostics = false});

  @override
  State<InputTestScreen> createState() => _InputTestScreenState();
}

class _InputTestScreenState extends State<InputTestScreen> with WidgetsBindingObserver {
  late final AppState _app;
  StreamSubscription<InputNoteEvent>? _midiSub;
  StreamSubscription<InputNoteEvent>? _micSub;
  MicService? _mic; // created on the user's tap only
  bool _micStarted = false;
  bool _micPaused = false;
  final Stopwatch _clock = Stopwatch()..start();
  final List<_Heard> _history = [];
  int _lo = 48, _hi = 84;
  late bool _labels;
  bool _hear = true;
  _Heard? _last;

  @override
  void initState() {
    super.initState();
    _app = context.read<AppState>();
    _labels = _app.settings.noteNames;
    _midiSub = _app.midi.notes.listen(_onMidi);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _midiSub?.cancel();
    _micSub?.cancel();
    _allOff();
    final mic = _mic;
    if (mic != null) unawaited(mic.stop().catchError((Object _) {}));
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _allOff();
      if (_mic?.isListening ?? false) _pauseMic();
    }
  }

  void _pauseMic() {
    final mic = _mic;
    if (mic == null) return;
    setState(() => _micPaused = true);
    unawaited(mic.stop().catchError((Object _) {}));
  }

  void _allOff() {
    try {
      _app.audio.allOff();
    } catch (_) {}
  }

  void _onMidi(InputNoteEvent e) {
    if (!mounted || _app.activeInput != InputKind.midi) return;
    if (_hear) {
      try {
        e.on ? _app.audio.noteOn(e.midi, e.velocity) : _app.audio.noteOff(e.midi);
      } catch (_) {}
    }
    if (e.on) _record(e.midi, null);
  }

  void _onMic(InputNoteEvent e) {
    if (mounted && e.on && _app.activeInput == InputKind.mic) _record(e.midi, e.confidence);
  }

  void _record(int midi, double? confidence) {
    final h = _Heard(midi, _clock.elapsed, confidence);
    final (lo, hi) = KeyWindow.follow(_lo, _hi, midi);
    setState(() {
      _last = h;
      _lo = lo;
      _hi = hi;
      _history.insert(0, h);
      if (_history.length > 40) _history.removeLast();
    });
  }

  Future<void> _startMic() async {
    final mic = _mic ??= _app.mic;
    _micSub ??= mic.notes.listen(_onMic);
    setState(() {
      _micStarted = true;
      _micPaused = false;
    });
    try {
      await mic.start();
    } catch (_) {}
    if (mounted) setState(() {});
  }

  Future<void> _openCalibration(InputKind kind) async {
    if (_mic?.isListening ?? false) _pauseMic();
    _allOff();
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => CalibrationScreen(initialInput: kind)));
  }

  Future<void> _openSettings() async {
    try {
      await openAppSettings();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(const SnackBar(content: Text('Open your phone’s Settings app and allow the microphone for Stavelight.')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final listenables = <Listenable>[app.midi, ?_mic];
    return Scaffold(
      appBar: AppBar(title: Text(widget.diagnostics ? 'Input diagnostics' : 'Free play')),
      body: SafeArea(
        child: ListenableBuilder(listenable: Listenable.merge(listenables), builder: (context, _) => _body(context, app)),
      ),
    );
  }

  Widget _body(BuildContext context, AppState app) {
    final kind = app.activeInput;
    final mic = _mic;
    final states = <int, KeyState>{};
    if (kind == InputKind.midi) {
      for (final n in app.midi.held) {
        states[n] = const KeyState(KeyMark.played);
      }
    } else if (kind == InputKind.mic && mic != null && mic.isListening && mic.currentNote != null) {
      final unsure = _last?.uncertain ?? false;
      states[mic.currentNote!] = KeyState(unsure ? KeyMark.uncertain : KeyMark.played);
    }
    final kbHeight = (MediaQuery.sizeOf(context).height * 0.22).clamp(96.0, 170.0);

    return Column(
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, c) {
              final side = c.maxWidth > 752 ? (c.maxWidth - 720) / 2 : 16.0;
              return ListView(
                padding: EdgeInsets.fromLTRB(side, 4, side, 16),
                children: [
                  InfoBanner(
                    widget.diagnostics
                        ? 'Nothing is scored here. These are the raw values Stavelight receives from your input.'
                        : 'Nothing is scored here. Play anything — notes are shown, never judged.',
                    icon: Icons.spa_outlined,
                  ),
                  const SizedBox(height: 12),
                  _inputRow(context, app, kind),
                  const SizedBox(height: 12),
                  ..._inputState(context, app, kind),
                  _currentNote(context, app, kind),
                  SectionTitle('Recent notes'),
                  _historyStrip(context),
                  SectionTitle('Options'),
                  _options(context, kind),
                  if (widget.diagnostics && kind != InputKind.none) ...[
                    SectionTitle('Raw values'),
                    kind == InputKind.midi ? _midiDiagnostics(context, app) : _micDiagnostics(context, mic),
                  ],
                ],
              );
            },
          ),
        ),
        SizedBox(
          height: kbHeight,
          child: PianoKeyboard(
            layoutFor: (w) => KeyLayout(_lo, _hi, w),
            states: states,
            labels: _labels,
            octaveLabels: app.settings.octaveLabels,
            highContrast: app.settings.highContrast,
          ),
        ),
      ],
    );
  }

  Widget _inputRow(BuildContext context, AppState app, InputKind kind) {
    final (icon, label) = switch (kind) {
      InputKind.midi => (Icons.piano, 'Listening to MIDI · ${app.midi.connected?.name ?? 'keyboard'}'),
      InputKind.mic => (Icons.mic_none, 'Listening to the microphone'),
      InputKind.none => (Icons.help_outline, 'No input selected'),
    };
    return Row(
      children: [
        Icon(icon, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 10),
        Expanded(child: Text(label, style: Theme.of(context).textTheme.titleSmall)),
        TextButton(
          onPressed: () => _openCalibration(kind == InputKind.mic ? InputKind.mic : InputKind.midi),
          child: const Text('Input setup'),
        ),
      ],
    );
  }

  List<Widget> _inputState(BuildContext context, AppState app, InputKind kind) {
    final t = Theme.of(context).textTheme;
    final gap = const SizedBox(height: 12);
    if (kind == InputKind.none) {
      return [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Choose how Stavelight should hear you', style: t.titleMedium),
                const SizedBox(height: 6),
                const Text('A MIDI keyboard is the most accurate. The microphone works with any acoustic piano.'),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: () => _openCalibration(InputKind.midi),
                      icon: const Icon(Icons.piano),
                      label: const Text('Connect a MIDI keyboard'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => _openCalibration(InputKind.mic),
                      icon: const Icon(Icons.mic_none),
                      label: const Text('Calibrate microphone'),
                    ),
                    TextButton(
                      onPressed: () => app.updateSettings((s) => s.preferredInput = 'mic'),
                      child: const Text('Use microphone without calibrating'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        gap,
      ];
    }
    if (kind == InputKind.midi) {
      return const [];
    }
    final mic = _mic;
    final out = <Widget>[];
    final cal = app.calibrations['mic'];
    if (cal == null || !cal.confirmed) {
      out.addAll([
        InfoBanner(
          'The microphone isn’t calibrated yet, so notes may appear in the wrong octave.',
          icon: Icons.tune,
          color: SlColors.warn,
          action: TextButton(onPressed: () => _openCalibration(InputKind.mic), child: const Text('Calibrate')),
        ),
        gap,
      ]);
    }
    final useMidi = TextButton(onPressed: () => _openCalibration(InputKind.midi), child: const Text('Use MIDI instead'));
    if (!_micStarted || mic == null || _micPaused || mic.status == MicStatus.off) {
      out.addAll([
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(_micPaused ? 'Microphone paused' : 'Start listening', style: t.titleMedium),
                const SizedBox(height: 6),
                const Text(
                  'Audio is analyzed live on this phone and never recorded or uploaded. '
                  'The microphone hears one main note at a time.',
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    FilledButton.icon(
                      onPressed: _startMic,
                      icon: const Icon(Icons.mic),
                      label: Text(_micPaused ? 'Resume listening' : 'Start listening'),
                    ),
                    HelpButton('mic'),
                  ],
                ),
              ],
            ),
          ),
        ),
        gap,
      ]);
    } else if (mic.status == MicStatus.requesting) {
      out.addAll([
        Row(
          children: [
            const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 3)),
            const SizedBox(width: 12),
            Expanded(child: Text('Waiting for microphone permission…', style: t.bodyLarge)),
          ],
        ),
        gap,
      ]);
    } else if (mic.status == MicStatus.denied) {
      out.addAll([
        const InfoBanner(
          'Microphone access is turned off. Allow it in Settings, then come back and tap Try again — or use a MIDI keyboard.',
          icon: Icons.mic_off,
          color: SlColors.warn,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            FilledButton.icon(onPressed: _openSettings, icon: const Icon(Icons.settings), label: const Text('Open settings')),
            OutlinedButton(onPressed: _startMic, child: const Text('Try again')),
            useMidi,
          ],
        ),
        gap,
      ]);
    } else if (mic.status == MicStatus.error) {
      out.addAll([
        InfoBanner(
          'The microphone couldn’t start${mic.error == null ? '' : ' (${mic.error})'}.',
          icon: Icons.error_outline,
          color: SlColors.bad,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            OutlinedButton(onPressed: _startMic, child: const Text('Try again')),
            useMidi,
          ],
        ),
        gap,
      ]);
    }
    return out;
  }

  Widget _currentNote(BuildContext context, AppState app, InputKind kind) {
    final t = Theme.of(context).textTheme;
    final last = _last;
    final held = kind == InputKind.midi ? (app.midi.held.toList()..sort()) : const <int>[];
    final uncertain = last?.uncertain ?? false;
    final color = uncertain ? SlColors.unsure : Theme.of(context).colorScheme.onSurface;
    return Semantics(
      liveRegion: true,
      label: last == null
          ? 'No note yet'
          : '${uncertain ? 'Possibly ' : ''}${Pitch.spokenName(last.midi)}${uncertain ? ', uncertain' : ''}',
      excludeSemantics: true,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Wrap(
            spacing: 20,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                last == null ? '—' : '${Pitch.name(last.midi)}${uncertain ? '?' : ''}',
                style: t.displayLarge?.copyWith(fontWeight: FontWeight.w700, color: color),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(last == null ? 'Play a note' : CalibrationMath.octaveHint(last.midi), style: t.bodyLarge),
                  if (last != null) ...[const SizedBox(height: 6), ConfidenceBadge(last.confidence)],
                  if (uncertain) ...[const SizedBox(height: 6), Text('Not sure — shown in grey, never as a mistake.', style: t.bodySmall)],
                  if (held.length > 1) ...[
                    const SizedBox(height: 6),
                    Text('Holding ${held.map(Pitch.name).join(' ')}', style: t.bodyMedium),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _historyStrip(BuildContext context) {
    final t = Theme.of(context).textTheme;
    if (_history.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Text('Notes you play will appear here.', style: t.bodyMedium),
      );
    }
    final height = MediaQuery.textScalerOf(context).scale(44) + 28;
    return SizedBox(
      height: height,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _history.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final h = _history[i];
          final secs = (h.at.inMilliseconds / 1000).toStringAsFixed(1);
          final c = h.confidence;
          final fg = h.uncertain ? SlColors.unsure : Theme.of(context).colorScheme.onSurface;
          final badge = c == null ? 'MIDI' : (h.uncertain ? '?' : '${(c * 100).round()}%');
          return Semantics(
            label:
                '${h.uncertain ? 'Possibly ' : ''}${Pitch.spokenName(h.midi)} at $secs seconds'
                '${c == null
                    ? ''
                    : h.uncertain
                    ? ', uncertain'
                    : ', confidence ${(c * 100).round()} percent'}',
            excludeSemantics: true,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: (h.uncertain ? SlColors.unsure : Theme.of(context).colorScheme.primary).withValues(alpha: i == 0 ? 0.16 : 0.07),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: fg.withValues(alpha: 0.25)),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${Pitch.name(h.midi)}${h.uncertain ? '?' : ''}',
                    style: t.titleMedium?.copyWith(color: fg, fontWeight: FontWeight.w600),
                  ),
                  Text('${secs}s · $badge', style: t.labelSmall?.copyWith(color: fg)),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _options(BuildContext context, InputKind kind) {
    final isMidi = kind == InputKind.midi;
    return Card(
      child: Column(
        children: [
          SwitchListTile(title: const Text('Note names on keys'), value: _labels, onChanged: (v) => setState(() => _labels = v)),
          SwitchListTile(
            title: const Text('Hear my notes'),
            subtitle: Text(isMidi ? 'Play MIDI notes through the phone speaker' : 'MIDI only — off for the microphone to avoid feedback'),
            value: isMidi && _hear,
            onChanged: isMidi
                ? (v) {
                    setState(() => _hear = v);
                    if (!v) _allOff();
                  }
                : null,
          ),
        ],
      ),
    );
  }

  Widget _midiDiagnostics(BuildContext context, AppState app) {
    final m = app.midi;
    final off = m.profile?.totalOffset ?? 0;
    return _KvCard(
      rows: [
        ('Device', m.connected?.name ?? 'None'),
        ('Raw note number', m.lastRawNote == null ? '—' : '${m.lastRawNote} (${Pitch.name(m.lastRawNote!)})'),
        ('Corrected note', m.lastNote == null ? '—' : '${m.lastNote} (${Pitch.name(m.lastNote!)})'),
        ('Calibration offset', CalibrationMath.semitoneLabel(off)),
        ('Velocity', m.lastNote == null ? '—' : '${m.lastVelocity}'),
        ('Sustain (CC64)', m.sustainDown ? 'Down' : 'Up'),
        ('Keys held', m.held.isEmpty ? 'None' : (m.held.toList()..sort()).map(Pitch.name).join(' ')),
      ],
    );
  }

  Widget _micDiagnostics(BuildContext context, MicService? mic) {
    if (mic == null || !mic.isListening) {
      return const _KvCard(rows: [('Status', 'Microphone off — start listening to see raw values')]);
    }
    final p = mic.profile;
    final f = mic.lastFrame;
    final hz = f?.hz;
    String raw = '—', corrected = '—', cents = '—';
    if (hz != null) {
      final (n, c) = CalibrationMath.nearest(hz, a4: p.a4Hz);
      raw = '$n (${Pitch.name(n)})';
      corrected = '${p.correct(n)} (${Pitch.name(p.correct(n))})';
      cents = CalibrationMath.centsLabel(c);
    }
    final conf = _last?.confidence;
    return _KvCard(
      header: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('RMS level', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          InputLevelMeter(level: mic.level, noiseFloor: p.noiseFloor > 0 ? p.noiseFloor : mic.noiseEstimate, gate: mic.tracker.gate),
          const SizedBox(height: 12),
        ],
      ),
      rows: [
        ('Frequency', hz == null ? 'No pitch' : '${hz.toStringAsFixed(1)} Hz'),
        ('Tuning (A4 = ${p.a4Hz.round()} Hz)', cents),
        ('Clarity', f == null ? '—' : '${(f.clarity * 100).round()}%'),
        ('RMS', mic.level.toStringAsFixed(4)),
        ('Noise floor (calibrated)', p.noiseFloor > 0 ? p.noiseFloor.toStringAsFixed(4) : 'Not measured'),
        ('Noise estimate (live)', mic.noiseEstimate.toStringAsFixed(4)),
        ('Gate', mic.tracker.gate.toStringAsFixed(4)),
        ('Raw MIDI', raw),
        ('After calibration (${CalibrationMath.semitoneLabel(p.totalOffset)})', corrected),
        ('Current note', mic.currentNote == null ? 'None' : Pitch.name(mic.currentNote!)),
        ('Last confidence', conf == null ? '—' : '${(conf * 100).round()}%${conf < CalibrationMath.minConfidence ? ' (uncertain)' : ''}'),
      ],
    );
  }
}

class _KvCard extends StatelessWidget {
  final Widget? header;
  final List<(String, String)> rows;
  const _KvCard({this.header, required this.rows});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ?header,
            for (final (k, v) in rows)
              MergeSemantics(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    spacing: 12,
                    children: [
                      Text(k, style: t.bodyMedium),
                      Text(
                        v,
                        style: t.bodyMedium?.copyWith(fontWeight: FontWeight.w600, fontFeatures: const [FontFeature.tabularFigures()]),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
