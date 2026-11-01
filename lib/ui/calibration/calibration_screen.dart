import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_midi_command/flutter_midi_command.dart' show MidiDevice, MidiDeviceType;
import 'package:permission_handler/permission_handler.dart' show openAppSettings;
import 'package:provider/provider.dart';

import '../../app/app_state.dart';
import '../../core/model/calibration.dart';
import '../../core/model/pitch.dart';
import '../../core/model/session.dart';
import '../../core/practice/input_event.dart';
import '../../services/mic_service.dart';
import '../../services/midi_service.dart';
import '../render/keyboard.dart';
import '../theme.dart';
import '../widgets/common.dart';

// ---- Pure calibration logic (unit-tested) ---------------------------------------------------------

enum NoiseLevel { quiet, moderate, noisy }

enum ReferenceOutcome { noSignal, unclear, match, octaveOff, wrongNote }

/// Result of listening for one reference note.
class ReferenceCheck {
  final int expected;
  final int? heard;
  final double confidence;
  final ReferenceOutcome outcome;
  const ReferenceCheck(this.expected, this.heard, this.confidence, this.outcome);

  /// How many octaves above (+) or below (−) the expected note the detector heard.
  int get octaveDelta => heard == null ? 0 : ((heard! - expected) / 12).round();

  /// Change to [CalibrationProfile.octaveOffset] that makes the heard note read as expected.
  int get suggestedOctaveChange => -octaveDelta;
}

/// Calibration maths kept free of widgets so it can be unit-tested.
abstract final class CalibrationMath {
  static const middleC = 60;

  /// Below this, a mic detection is "uncertain" and never counts as a success.
  static const minConfidence = 0.6;

  /// Noise-floor RMS thresholds (full scale = 1.0).
  static const quietRms = 0.005;
  static const noisyRms = 0.015;

  static double median(Iterable<double> values) {
    final xs = values.where((v) => v.isFinite).toList()..sort();
    if (xs.isEmpty) return 0;
    final m = xs.length ~/ 2;
    return xs.length.isOdd ? xs[m] : (xs[m - 1] + xs[m]) / 2;
  }

  static NoiseLevel classifyNoise(double rms) =>
      rms < quietRms ? NoiseLevel.quiet : (rms < noisyRms ? NoiseLevel.moderate : NoiseLevel.noisy);

  /// RMS → 0..1 on a log (dB) scale from −60 dBFS to 0 dBFS.
  static double meter(double rms) {
    if (rms <= 0) return 0;
    final db = 20 * math.log(rms) / math.ln10;
    return ((db + 60) / 60).clamp(0.0, 1.0);
  }

  /// Nearest MIDI note to [hz] and its deviation in cents (−50..50).
  static (int, double) nearest(double hz, {double a4 = 440}) {
    final mf = Pitch.midiFromFrequency(hz, a4: a4);
    final n = mf.round();
    return (n, (mf - n) * 100);
  }

  /// Dominant note among heard (midi, confidence) pairs. Confidence is scaled by how much of the
  /// evidence agrees, so flapping between C4 and C5 comes out as uncertain.
  static (int, double)? dominant(Iterable<(int, double)> heard) {
    final weight = <int, double>{};
    final best = <int, double>{};
    var total = 0.0;
    for (final (m, c) in heard) {
      final w = math.max(c, 0.05);
      weight[m] = (weight[m] ?? 0) + w;
      best[m] = math.max(best[m] ?? 0, c);
      total += w;
    }
    if (weight.isEmpty) return null;
    final top = weight.entries.reduce((a, b) => b.value > a.value ? b : a);
    return (top.key, best[top.key]! * (top.value / total));
  }

  static ReferenceCheck checkReference(int expected, int? heard, double confidence, {bool sawSignal = false}) {
    if (heard == null) {
      return ReferenceCheck(expected, null, 0, sawSignal ? ReferenceOutcome.unclear : ReferenceOutcome.noSignal);
    }
    if (confidence < minConfidence) return ReferenceCheck(expected, heard, confidence, ReferenceOutcome.unclear);
    if (heard == expected) return ReferenceCheck(expected, heard, confidence, ReferenceOutcome.match);
    if (Pitch.pitchClass(heard) == Pitch.pitchClass(expected)) {
      return ReferenceCheck(expected, heard, confidence, ReferenceOutcome.octaveOff);
    }
    return ReferenceCheck(expected, heard, confidence, ReferenceOutcome.wrongNote);
  }

  /// Total semitone offset that makes a raw MIDI [raw] from the pressed key read as [expected].
  static int midiCorrection(int raw, {int expected = middleC}) => expected - raw;

  /// Signed number with a real minus sign.
  static String signed(int n) => n > 0 ? '+$n' : (n < 0 ? '−${-n}' : '0');

  static String semitoneLabel(int n) {
    if (n != 0 && n % 12 == 0) {
      final o = n ~/ 12;
      return '${signed(o)} ${o.abs() == 1 ? 'octave' : 'octaves'}';
    }
    return '${signed(n)} ${n.abs() == 1 ? 'semitone' : 'semitones'}';
  }

  static String octaveHint(int midi) {
    if (midi == middleC) return 'middle C';
    final d = midi - middleC;
    if (d % 12 == 0) {
      final o = d.abs() ~/ 12;
      return '${o == 1 ? 'one octave' : '$o octaves'} ${d > 0 ? 'above' : 'below'} middle C';
    }
    return 'octave ${Pitch.octaveOf(midi)}';
  }

  static String centsLabel(double cents) {
    final c = cents.round();
    if (c.abs() <= 5) return 'In tune (${signed(c)} cents)';
    return '${signed(c)} cents (${c > 0 ? 'sharp' : 'flat'})';
  }
}

// ---- Shared small widgets ---------------------------------------------------------------------------

/// Confidence pill. `null` means an exact MIDI reading.
class ConfidenceBadge extends StatelessWidget {
  final double? confidence;
  const ConfidenceBadge(this.confidence, {super.key});

  @override
  Widget build(BuildContext context) {
    final c = confidence;
    final (icon, color, text) = c == null
        ? (Icons.check_circle, SlColors.good, 'Exact (MIDI)')
        : c >= 0.8
        ? (Icons.check_circle_outline, SlColors.good, 'Confidence ${(c * 100).round()}%')
        : c >= CalibrationMath.minConfidence
        ? (Icons.adjust, SlColors.warn, 'Confidence ${(c * 100).round()}%')
        : (Icons.help_outline, SlColors.unsure, 'Uncertain ${(c * 100).round()}%');
    return Semantics(
      label: text,
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: 0.45)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 6),
            Flexible(child: Text(text, style: Theme.of(context).textTheme.labelLarge)),
          ],
        ),
      ),
    );
  }
}

/// Horizontal log-scale input meter with optional noise-floor and gate markers.
class InputLevelMeter extends StatelessWidget {
  final double level;
  final double? noiseFloor;
  final double? gate;
  const InputLevelMeter({super.key, required this.level, this.noiseFloor, this.gate});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final pct = (CalibrationMath.meter(level) * 100).round();
    return Semantics(
      label: 'Input level $pct percent',
      child: SizedBox(
        height: 16,
        width: double.infinity,
        child: CustomPaint(
          painter: _MeterPainter(
            value: CalibrationMath.meter(level),
            floor: noiseFloor == null ? null : CalibrationMath.meter(noiseFloor!),
            gate: gate == null ? null : CalibrationMath.meter(gate!),
            track: scheme.surfaceContainerHighest,
            fill: gate != null && level >= gate! ? scheme.primary : scheme.primary.withValues(alpha: 0.45),
            marker: scheme.onSurface,
            floorColor: SlColors.warn,
          ),
        ),
      ),
    );
  }
}

class _MeterPainter extends CustomPainter {
  final double value;
  final double? floor;
  final double? gate;
  final Color track, fill, marker, floorColor;
  _MeterPainter({
    required this.value,
    this.floor,
    this.gate,
    required this.track,
    required this.fill,
    required this.marker,
    required this.floorColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final r = Radius.circular(size.height / 2);
    canvas.drawRRect(RRect.fromRectAndRadius(Offset.zero & size, r), Paint()..color = track);
    if (value > 0) {
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, size.width * value, size.height), r), Paint()..color = fill);
    }
    void tick(double? v, Color c) {
      if (v == null) return;
      final x = size.width * v;
      canvas.drawLine(
        Offset(x, -2),
        Offset(x, size.height + 2),
        Paint()
          ..color = c
          ..strokeWidth = 2,
      );
    }

    tick(floor, floorColor);
    tick(gate, marker);
  }

  @override
  bool shouldRepaint(_MeterPainter old) => old.value != value || old.floor != floor || old.gate != gate || old.fill != fill;
}

/// Calibration status label for a saved profile.
(String, IconData, Color) calibrationStatus(CalibrationProfile? p, {bool dirty = false}) {
  if (p == null || p.calibratedAt == null) return ('Not calibrated', Icons.radio_button_unchecked, SlColors.unsure);
  if (dirty || !p.confirmed) return ('Needs confirmation', Icons.error_outline, SlColors.warn);
  return ('Calibrated on ${formatDate(p.calibratedAt!)}', Icons.verified, SlColors.good);
}

/// Scrollable panel body, centred and width-limited for tablets/landscape. The [header] stays pinned
/// above the list when there is room, otherwise it scrolls with the content.
class _PanelList extends StatelessWidget {
  final Widget header;
  final List<Widget> children;
  const _PanelList({required this.header, required this.children});

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      final side = math.max(16.0, (c.maxWidth - 720) / 2);
      final pin = c.maxHeight >= 560;
      final list = ListView(
        padding: EdgeInsets.fromLTRB(side, pin ? 12 : 4, side, 32),
        children: [
          if (!pin) ...[header, const SizedBox(height: 12)],
          ...children,
        ],
      );
      if (!pin) return list;
      return Column(
        children: [
          Padding(padding: EdgeInsets.fromLTRB(side, 4, side, 0), child: header),
          Expanded(child: list),
        ],
      );
    },
  );
}

class _StatusCard extends StatelessWidget {
  final String input;
  final int? note;
  final double? confidence;
  final bool exact;
  final String placeholder;
  final (String, IconData, Color) status;
  const _StatusCard({
    required this.input,
    required this.note,
    required this.status,
    this.confidence,
    this.exact = false,
    this.placeholder = 'No note yet',
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final n = note;
    final uncertain = !exact && confidence != null && confidence! < CalibrationMath.minConfidence;
    final noteText = n == null ? '—' : '${Pitch.name(n)}${uncertain ? '?' : ''}';
    return Semantics(
      container: true,
      label:
          'Input status. $input. ${n == null ? placeholder : 'Detected ${Pitch.spokenName(n)}${uncertain ? ', uncertain' : ''}'}. ${status.$1}',
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Wrap(
            spacing: 24,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ExcludeSemantics(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      noteText,
                      style: t.displayMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: uncertain ? SlColors.unsure : Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    Text(n == null ? placeholder : CalibrationMath.octaveHint(n), style: t.bodyMedium),
                  ],
                ),
              ),
              ExcludeSemantics(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(input, style: t.titleSmall),
                    const SizedBox(height: 4),
                    Text(n == null ? 'Octave —' : 'Octave ${Pitch.octaveOf(n)}', style: t.bodyMedium),
                    const SizedBox(height: 6),
                    if (n != null) ConfidenceBadge(exact ? null : confidence),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(status.$2, size: 18, color: status.$3),
                        const SizedBox(width: 6),
                        Flexible(child: Text(status.$1, style: t.labelLarge)),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Bullet extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Bullet(this.icon, this.text);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 10),
        Expanded(child: Text(text)),
      ],
    ),
  );
}

/// Labelled −/+ stepper with 48dp targets.
class _Stepper extends StatelessWidget {
  final String label;
  final String value;
  final String unit;
  final VoidCallback? onMinus;
  final VoidCallback? onPlus;
  const _Stepper({required this.label, required this.value, required this.unit, this.onMinus, this.onPlus});

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: '$label $value',
    child: Row(
      children: [
        Expanded(child: Text(label, style: Theme.of(context).textTheme.bodyLarge)),
        IconButton.outlined(tooltip: 'Lower $unit', onPressed: onMinus, icon: const Icon(Icons.remove)),
        ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 56),
          child: Text(value, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
        ),
        IconButton.outlined(tooltip: 'Raise $unit', onPressed: onPlus, icon: const Icon(Icons.add)),
      ],
    ),
  );
}

// ---- Screen -------------------------------------------------------------------------------------------

/// Input setup: connect/test a MIDI keyboard or calibrate the microphone so a correct pitch is never
/// judged as the wrong octave.
class CalibrationScreen extends StatefulWidget {
  final InputKind? initialInput;
  const CalibrationScreen({super.key, this.initialInput});

  @override
  State<CalibrationScreen> createState() => _CalibrationScreenState();
}

class _CalibrationScreenState extends State<CalibrationScreen> {
  late InputKind _kind;

  @override
  void initState() {
    super.initState();
    final pref = context.read<AppState>().settings.preferredInput;
    _kind = switch (widget.initialInput) {
      InputKind.mic => InputKind.mic,
      InputKind.midi => InputKind.midi,
      _ => pref == 'mic' ? InputKind.mic : InputKind.midi,
    };
  }

  void _select(InputKind k) => setState(() => _kind = k);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Input setup'), actions: [HelpButton(_kind == InputKind.mic ? 'mic' : 'midi', size: 24)]),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<InputKind>(
                    showSelectedIcon: false,
                    style: const ButtonStyle(minimumSize: WidgetStatePropertyAll(Size(48, 52))),
                    segments: const [
                      ButtonSegment(value: InputKind.midi, icon: Icon(Icons.piano), label: Text('MIDI keyboard')),
                      ButtonSegment(value: InputKind.mic, icon: Icon(Icons.mic_none), label: Text('Microphone')),
                    ],
                    selected: {_kind},
                    onSelectionChanged: (s) => _select(s.first),
                  ),
                ),
              ),
            ),
            Expanded(
              child: _kind == InputKind.midi
                  ? _MidiPanel(key: const ValueKey('midi'), onUseMic: () => _select(InputKind.mic))
                  : _MicPanel(key: const ValueKey('mic'), onUseMidi: () => _select(InputKind.midi)),
            ),
          ],
        ),
      ),
    );
  }
}

// ---- MIDI -------------------------------------------------------------------------------------------

class _MidiPanel extends StatefulWidget {
  final VoidCallback onUseMic;
  const _MidiPanel({super.key, required this.onUseMic});

  @override
  State<_MidiPanel> createState() => _MidiPanelState();
}

class _MidiPanelState extends State<_MidiPanel> {
  StreamSubscription<InputNoteEvent>? _testSub;
  bool _testing = false;
  int? _testRaw;
  String? _saveMessage;

  @override
  void dispose() {
    _testSub?.cancel();
    super.dispose();
  }

  Future<void> _guard(Future<void> Function() f) async {
    try {
      await f();
    } catch (e) {
      if (mounted) setState(() => _saveMessage = 'Something went wrong: $e');
    }
  }

  Future<void> _scanBluetooth(MidiService midi) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        icon: const Icon(Icons.bluetooth_searching),
        title: const Text('Scan for Bluetooth MIDI'),
        content: const Text(
          'Your phone will now ask for Bluetooth permission so Stavelight can find nearby MIDI keyboards. '
          'Turn on your keyboard and its Bluetooth MIDI mode first. The scan takes about 8 seconds.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Not now')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Continue')),
        ],
      ),
    );
    if (ok == true) await _guard(midi.scanBluetooth);
  }

  void _startTest(AppState app) {
    final midi = app.midi;
    _testSub?.cancel();
    setState(() {
      _testing = true;
      _testRaw = null;
      _saveMessage = null;
    });
    _testSub = midi.notes.listen((e) {
      if (!e.on || !mounted) return;
      final raw = e.midi - (midi.profile?.totalOffset ?? 0); // MidiService applies midi.profile
      _testSub?.cancel();
      _testSub = null;
      setState(() {
        _testing = false;
        _testRaw = raw;
      });
      final d = midi.connected;
      if (d != null && app.midiProfile(d.name).correct(raw) == CalibrationMath.middleC) _save(app, d);
    });
  }

  void _cancelTest() {
    _testSub?.cancel();
    _testSub = null;
    setState(() => _testing = false);
  }

  Future<void> _save(AppState app, MidiDevice d) => _guard(() async {
    await app.saveCalibration(app.midiProfile(d.name)..confirmed = true);
    if (mounted) setState(() => _saveMessage = 'Saved for ${d.name}.');
  });

  void _applyCorrection(AppState app, MidiDevice d, int raw) {
    final p = app.midiProfile(d.name)
      ..octaveOffset = 0
      ..semitoneOffset = CalibrationMath.midiCorrection(raw);
    setState(() {});
    _save(app, d).then((_) {
      if (mounted) setState(() => _saveMessage = 'Correction ${CalibrationMath.semitoneLabel(p.totalOffset)} saved for ${d.name}.');
    });
  }

  void _manual(AppState app, MidiDevice d, {int octave = 0, int semis = 0}) {
    final p = app.midiProfile(d.name);
    p.octaveOffset = (p.octaveOffset + octave).clamp(-4, 4);
    p.semitoneOffset = (p.semitoneOffset + semis).clamp(-24, 24);
    setState(() {});
    _save(app, d);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return ListenableBuilder(listenable: app.midi, builder: (context, _) => _build(context, app, app.midi));
  }

  Widget _build(BuildContext context, AppState app, MidiService midi) {
    final t = Theme.of(context).textTheme;
    final device = midi.connected;
    final saved = device == null ? null : app.calibrations['midi:${device.name}'];
    final status = device == null ? ('No keyboard connected', Icons.link_off, SlColors.unsure) : calibrationStatus(saved);
    final unavailable = midi.status == MidiStatus.unavailable;

    return _PanelList(
      header: _StatusCard(
        input: device == null ? 'MIDI keyboard' : 'MIDI · ${device.name}',
        note: device == null ? null : midi.lastNote,
        exact: true,
        placeholder: device == null ? 'Connect a keyboard' : 'Press any key',
        status: status,
      ),
      children: [
        const InfoBanner(
          'MIDI is the most accurate input: it reports exactly which key you press, when you release it, '
          'and the sustain pedal. It does not use the microphone.',
          icon: Icons.verified_outlined,
        ),
        if (unavailable) ...[
          const SizedBox(height: 12),
          InfoBanner(
            'MIDI isn’t available on this device right now. You can still use the microphone.',
            icon: Icons.portable_wifi_off,
            color: SlColors.warn,
            action: TextButton(onPressed: widget.onUseMic, child: const Text('Use microphone')),
          ),
          if (midi.error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
              child: Text('Details: ${midi.error}', style: t.bodySmall, maxLines: 3, overflow: TextOverflow.ellipsis),
            ),
        ] else if (midi.error != null) ...[
          const SizedBox(height: 12),
          InfoBanner(midi.error!, icon: Icons.error_outline, color: SlColors.bad),
        ],
        if (midi.status == MidiStatus.disconnected) ...[
          const SizedBox(height: 12),
          InfoBanner(
            'Keyboard disconnected — reconnect it or choose another input.',
            icon: Icons.usb_off,
            color: SlColors.warn,
            action: TextButton(onPressed: widget.onUseMic, child: const Text('Use microphone')),
          ),
        ],
        SectionTitle('Devices', trailing: HelpButton('midi')),
        _devices(context, midi),
        if (device != null) ...[
          SectionTitle('Live input'),
          _live(context, midi),
          SectionTitle('Key test'),
          _keyTest(context, app, midi, device),
          SectionTitle('Manual correction'),
          _manualCard(context, app, device),
        ],
      ],
    );
  }

  Widget _devices(BuildContext context, MidiService midi) {
    final t = Theme.of(context).textTheme;
    final scanning = midi.status == MidiStatus.scanning;
    final connecting = midi.status == MidiStatus.connecting;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (scanning || connecting)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const LinearProgressIndicator(),
                    const SizedBox(height: 8),
                    Text(scanning ? 'Looking for Bluetooth MIDI keyboards…' : 'Connecting…', style: t.bodyMedium),
                  ],
                ),
              ),
            if (midi.devices.isEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'No MIDI devices found. Plug your keyboard in by USB (on Android you may need an OTG adapter), '
                  'then tap Refresh — or scan for a Bluetooth MIDI keyboard.',
                  style: t.bodyMedium,
                ),
              )
            else
              for (final d in midi.devices) _deviceTile(context, midi, d, busy: scanning || connecting),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: scanning ? null : () => _guard(midi.refresh),
                    icon: const Icon(Icons.refresh),
                    label: const Text('Refresh'),
                  ),
                  OutlinedButton.icon(
                    onPressed: scanning ? null : () => _scanBluetooth(midi),
                    icon: const Icon(Icons.bluetooth_searching),
                    label: const Text('Scan for Bluetooth MIDI'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _deviceTile(BuildContext context, MidiService midi, MidiDevice d, {required bool busy}) {
    final isConnected = midi.connected?.id == d.id;
    final (icon, kind) = switch (d.type) {
      MidiDeviceType.ble => (Icons.bluetooth, 'Bluetooth'),
      MidiDeviceType.serial => (Icons.usb, 'USB / wired'),
      MidiDeviceType.network => (Icons.lan, 'Network'),
      _ => (Icons.piano, 'MIDI'),
    };
    return ListTile(
      minTileHeight: 64,
      leading: Icon(icon),
      title: Text(d.name.isEmpty ? 'Unnamed device' : d.name),
      subtitle: Text(isConnected ? '$kind · Connected' : kind),
      trailing: isConnected
          ? OutlinedButton(onPressed: busy ? null : () => _guard(() async => midi.disconnect()), child: const Text('Disconnect'))
          : FilledButton.tonal(onPressed: busy ? null : () => _guard(() async => midi.connect(d)), child: const Text('Connect')),
    );
  }

  Widget _live(BuildContext context, MidiService midi) {
    final t = Theme.of(context).textTheme;
    final held = midi.held.toSet();
    final last = midi.lastNote;
    Widget fact(String label, String value) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: t.labelMedium),
        Text(value, style: t.titleMedium),
      ],
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 24,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                fact('Last note', last == null ? '—' : '${Pitch.name(last)} ($last)'),
                fact('Raw note number', midi.lastRawNote?.toString() ?? '—'),
                fact('Velocity', last == null ? '—' : '${midi.lastVelocity}'),
                Semantics(
                  label: midi.sustainDown ? 'Sustain pedal down' : 'Sustain pedal up',
                  excludeSemantics: true,
                  child: Chip(
                    avatar: Icon(midi.sustainDown ? Icons.arrow_downward : Icons.arrow_upward, size: 18),
                    label: Text(midi.sustainDown ? 'Pedal down' : 'Pedal up'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 110,
              child: PianoKeyboard(
                layoutFor: (w) => KeyLayout.forNotes({...held, CalibrationMath.middleC}, w, minSpan: 24),
                states: {for (final n in held) n: const KeyState(KeyMark.played)},
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _keyTest(BuildContext context, AppState app, MidiService midi, MidiDevice device) {
    final t = Theme.of(context).textTheme;
    final raw = _testRaw;
    final profile = app.calibrations['midi:${device.name}'];
    final offset = profile?.totalOffset ?? 0;
    final children = <Widget>[
      Text('Press middle C — the C closest to the middle of your keyboard.', style: t.titleMedium),
      const SizedBox(height: 4),
      Text('This checks that your keyboard sends the notes Stavelight expects.', style: t.bodyMedium),
      const SizedBox(height: 12),
    ];
    if (_testing) {
      children.add(
        Row(
          children: [
            const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 3)),
            const SizedBox(width: 12),
            Expanded(child: Text('Waiting for a key…', style: t.bodyLarge)),
            TextButton(onPressed: _cancelTest, child: const Text('Cancel')),
          ],
        ),
      );
    } else if (raw == null) {
      children.add(
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            onPressed: () => _startTest(app),
            icon: const Icon(Icons.play_arrow),
            label: const Text('Start key test'),
          ),
        ),
      );
    } else if (raw + offset == CalibrationMath.middleC) {
      children.addAll([
        InfoBanner(
          raw == CalibrationMath.middleC
              ? 'Middle C detected (60). Your keyboard sends standard note numbers.'
              : 'Middle C detected with your correction (${CalibrationMath.semitoneLabel(offset)}). Raw note was ${Pitch.name(raw)} ($raw).',
          icon: Icons.check_circle,
          color: SlColors.good,
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(onPressed: () => _startTest(app), child: const Text('Test again')),
        ),
      ]);
    } else {
      final needed = CalibrationMath.midiCorrection(raw);
      final far = needed.abs() > 24;
      children.addAll([
        Semantics(
          liveRegion: true,
          child: Text('Detected ${Pitch.name(raw)} ($raw)', style: t.headlineSmall?.copyWith(fontWeight: FontWeight.w600)),
        ),
        const SizedBox(height: 4),
        Text(
          far
              ? 'That’s far from middle C — you may have pressed a different key. Try again with the C nearest the middle.'
              : 'If you pressed middle C, your keyboard may be transposed or set to a different octave '
                    '(many keyboards have Transpose or Octave buttons). Fix it on the keyboard, or let Stavelight correct it.',
          style: t.bodyMedium,
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            FilledButton(
              onPressed: () => _applyCorrection(app, device, raw),
              child: Text('Apply correction (${CalibrationMath.semitoneLabel(needed)})'),
            ),
            OutlinedButton(onPressed: () => _startTest(app), child: const Text('I pressed a different key')),
          ],
        ),
      ]);
    }
    if (_saveMessage != null) {
      children.addAll([const SizedBox(height: 8), Text(_saveMessage!, style: t.bodySmall)]);
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
      ),
    );
  }

  Widget _manualCard(BuildContext context, AppState app, MidiDevice device) {
    final p = app.calibrations['midi:${device.name}'];
    final oct = p?.octaveOffset ?? 0;
    final semi = p?.semitoneOffset ?? 0;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Shift every note from this keyboard. Changes apply immediately and are saved.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 8),
            _Stepper(
              label: 'Octave',
              value: CalibrationMath.signed(oct),
              unit: 'octave',
              onMinus: () => _manual(app, device, octave: -1),
              onPlus: () => _manual(app, device, octave: 1),
            ),
            _Stepper(
              label: 'Semitones',
              value: CalibrationMath.signed(semi),
              unit: 'semitone',
              onMinus: () => _manual(app, device, semis: -1),
              onPlus: () => _manual(app, device, semis: 1),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: oct == 0 && semi == 0 ? null : () => _manual(app, device, octave: -oct, semis: -semi),
                child: const Text('Reset to no correction'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---- Microphone -------------------------------------------------------------------------------------

enum _MicStep { noise, reference, done }

class _MicPanel extends StatefulWidget {
  final VoidCallback onUseMidi;
  const _MicPanel({super.key, required this.onUseMidi});

  @override
  State<_MicPanel> createState() => _MicPanelState();
}

class _MicPanelState extends State<_MicPanel> with WidgetsBindingObserver {
  static const _refs = [60, 72];
  static const _noiseTicks = 56; // × 50 ms ≈ 2.8 s, first 6 ticks discarded

  late final AppState _app;
  late CalibrationProfile _draft;
  MicService? _mic; // created only when the user taps start (constructing it touches the plugin)
  bool _started = false;
  bool _paused = false;
  bool _dirty = false;

  final _checklist = <String, bool>{
    'Quiet room': false,
    'Phone near the piano': false,
    'Play one note at a time': false,
    'No pedal during calibration': false,
  };

  _MicStep _step = _MicStep.noise;
  Timer? _noiseTimer;
  final List<double> _noiseSamples = [];
  double _noiseProgress = 0;
  double? _noiseFloor;

  int _refIndex = 0;
  final _confirmed = [false, false];
  bool _listening = false;
  ReferenceCheck? _result;
  final List<InputNoteEvent> _heard = [];
  int _uncertainCount = 0;
  Timer? _refTimeout;
  Timer? _settle;
  Timer? _arm;
  bool _armed = false;
  String? _notice;

  StreamSubscription<InputNoteEvent>? _noteSub;
  StreamSubscription<InputUncertainEvent>? _uncSub;
  InputNoteEvent? _last;

  static CalibrationProfile _copy(CalibrationProfile p) => CalibrationProfile.fromJson(p.toJson());

  @override
  void initState() {
    super.initState();
    _app = context.read<AppState>();
    _draft = _copy(_app.micProfile);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cancelTimers();
    _noteSub?.cancel();
    _uncSub?.cancel();
    final mic = _mic;
    if (mic != null) {
      mic.profile = _app.micProfile; // discard unsaved draft; the service is shared with practice
      _stopMic(mic);
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Not on `inactive`: permission prompts and the app switcher pass through it.
    if ((state == AppLifecycleState.paused || state == AppLifecycleState.hidden) && (_mic?.isListening ?? false)) {
      _cancelTimers();
      setState(() {
        _paused = true;
        _listening = false;
      });
      _stopMic(_mic!);
    }
  }

  void _stopMic(MicService mic) => unawaited(mic.stop().catchError((Object _) {}));

  void _cancelTimers() {
    _noiseTimer?.cancel();
    _noiseTimer = null;
    _cancelRefTimers();
  }

  void _cancelRefTimers() {
    _refTimeout?.cancel();
    _settle?.cancel();
    _arm?.cancel();
    _refTimeout = null;
    _settle = null;
    _arm = null;
  }

  Future<void> _startMic() async {
    final mic = _mic ??= _app.mic;
    mic.profile = _draft;
    _noteSub ??= mic.notes.listen(_onNote);
    _uncSub ??= mic.uncertain.listen((_) {
      if (_listening) _uncertainCount++;
    });
    setState(() {
      _started = true;
      _paused = false;
    });
    var ok = false;
    try {
      ok = await mic.start();
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    if (!ok) {
      setState(() {});
      return;
    }
    switch (_step) {
      case _MicStep.noise:
        _startNoise();
      case _MicStep.reference:
        _startReference();
      case _MicStep.done:
        setState(() {});
    }
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

  void _startNoise() {
    _cancelTimers();
    _noiseSamples.clear();
    setState(() {
      _step = _MicStep.noise;
      _noiseFloor = null;
      _noiseProgress = 0;
    });
    var ticks = 0;
    _noiseTimer = Timer.periodic(const Duration(milliseconds: 50), (t) {
      final mic = _mic;
      if (mic == null || !mic.isListening || !mounted) return;
      ticks++;
      if (ticks > 6) _noiseSamples.add(mic.level); // let the smoothed meter settle first
      if (ticks >= _noiseTicks) {
        t.cancel();
        final floor = CalibrationMath.median(_noiseSamples);
        _draft.noiseFloor = floor;
        _dirty = true;
        setState(() {
          _noiseFloor = floor;
          _noiseProgress = 1;
        });
      } else {
        setState(() => _noiseProgress = ticks / _noiseTicks);
      }
    });
  }

  void _startReference() {
    _cancelRefTimers();
    _heard.clear();
    _uncertainCount = 0;
    setState(() {
      _step = _MicStep.reference;
      _listening = true;
      _result = null;
    });
    _armed = false;
    // Ignore the tail of the previous note (or the button tap) for a moment.
    _arm = Timer(const Duration(milliseconds: 400), () => _armed = true);
    _refTimeout = Timer(const Duration(seconds: 8), _finishReference);
  }

  void _onNote(InputNoteEvent e) {
    if (!mounted || !e.on) return;
    setState(() => _last = e);
    if (!_listening || !_armed) return;
    _heard.add(e);
    _settle ??= Timer(const Duration(milliseconds: 900), _finishReference);
  }

  void _finishReference() {
    _cancelRefTimers();
    if (!mounted || !_listening) return;
    final d = CalibrationMath.dominant(_heard.map((e) => (e.midi, e.confidence)));
    setState(() {
      _listening = false;
      _result = CalibrationMath.checkReference(_refs[_refIndex], d?.$1, d?.$2 ?? 0, sawSignal: _uncertainCount > 0);
    });
  }

  void _confirmYes() {
    _confirmed[_refIndex] = true;
    if (_refIndex == 0) {
      setState(() {
        _refIndex = 1;
        _notice = null;
      });
      _startReference();
    } else {
      _finish();
    }
  }

  void _adjustOctave(int delta) {
    _draft.octaveOffset = (_draft.octaveOffset + delta).clamp(-3, 3);
    _dirty = true;
    _notice = null;
    if (_refIndex == 1 && _confirmed[0]) {
      // A single offset must work for both notes, so middle C has to be re-checked.
      _confirmed[0] = false;
      _refIndex = 0;
      _notice = 'Octave correction changed — let’s re-check middle C first.';
    }
    if (_mic?.isListening ?? false) {
      _startReference();
    } else {
      setState(() {});
    }
  }

  Future<void> _finish() async {
    _draft.confirmed = true;
    try {
      await _app.saveCalibration(_draft);
      await _app.updateSettings((s) => s.preferredInput = 'mic');
    } catch (e) {
      if (mounted) setState(() => _notice = 'Couldn’t save the calibration: $e');
      return;
    }
    if (!mounted) return;
    _draft = _copy(_app.micProfile);
    _mic?.profile = _draft;
    setState(() {
      _step = _MicStep.done;
      _dirty = false;
      _notice = null;
    });
  }

  void _recalibrate() {
    _confirmed.fillRange(0, 2, false);
    _refIndex = 0;
    _result = null;
    _notice = null;
    if (_mic?.isListening ?? false) {
      _startNoise();
    } else {
      setState(() => _step = _MicStep.noise);
    }
  }

  @override
  Widget build(BuildContext context) {
    final mic = _mic;
    if (mic == null) return _build(context, null);
    return ListenableBuilder(listenable: mic, builder: (context, _) => _build(context, mic));
  }

  Widget _build(BuildContext context, MicService? mic) {
    context.watch<AppState>(); // refresh saved-status after saveCalibration
    final saved = _app.calibrations['mic'];
    final note = mic?.currentNote ?? _last?.midi;
    return _PanelList(
      header: _StatusCard(
        input: 'Microphone',
        note: note,
        confidence: _last?.confidence,
        placeholder: mic?.isListening ?? false ? 'Listening…' : 'Microphone off',
        status: calibrationStatus(saved, dirty: _dirty && saved?.calibratedAt != null),
      ),
      children: [
        ..._body(context, mic),
        SectionTitle('Tuning & sensitivity'),
        _tuningCard(context, mic),
        SectionTitle('Limitations', trailing: HelpButton('mic')),
        _limitations(context),
      ],
    );
  }

  List<Widget> _body(BuildContext context, MicService? mic) {
    final t = Theme.of(context).textTheme;
    final useMidi = TextButton.icon(onPressed: widget.onUseMidi, icon: const Icon(Icons.piano), label: const Text('Use MIDI instead'));
    if (!_started || mic == null) return [_intro(context, useMidi)];
    if (_paused || (mic.status == MicStatus.off && _started)) {
      return [
        const InfoBanner(
          'Microphone paused. It stops whenever you leave this screen or the app goes to the background.',
          icon: Icons.pause_circle_outline,
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            FilledButton.icon(onPressed: _startMic, icon: const Icon(Icons.mic), label: const Text('Resume')),
            useMidi,
          ],
        ),
      ];
    }
    switch (mic.status) {
      case MicStatus.requesting:
        return [
          Row(
            children: [
              const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 3)),
              const SizedBox(width: 12),
              Expanded(child: Text('Waiting for microphone permission…', style: t.bodyLarge)),
            ],
          ),
        ];
      case MicStatus.denied:
        return [
          const InfoBanner(
            'Microphone access is turned off, so Stavelight can’t hear your piano. Audio is only analyzed live on this phone — '
            'never recorded or uploaded. Allow the microphone in Settings, then come back and tap Try again.',
            icon: Icons.mic_off,
            color: SlColors.warn,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              FilledButton.icon(onPressed: _openSettings, icon: const Icon(Icons.settings), label: const Text('Open settings')),
              OutlinedButton(onPressed: _startMic, child: const Text('Try again')),
              useMidi,
            ],
          ),
        ];
      case MicStatus.error:
        return [
          InfoBanner(
            'The microphone couldn’t start${mic.error == null ? '' : ' (${mic.error})'}.',
            icon: Icons.error_outline,
            color: SlColors.bad,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              FilledButton(onPressed: _startMic, child: const Text('Try again')),
              useMidi,
            ],
          ),
        ];
      case MicStatus.off:
      case MicStatus.listening:
        break;
    }
    return [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Input level', style: t.labelLarge),
              const SizedBox(height: 8),
              InputLevelMeter(level: mic.level, noiseFloor: _draft.noiseFloor > 0 ? _draft.noiseFloor : null, gate: mic.tracker.gate),
              const SizedBox(height: 6),
              Text('Orange mark: room noise · dark mark: loudest sound ignored', style: t.bodySmall),
            ],
          ),
        ),
      ),
      const SizedBox(height: 12),
      switch (_step) {
        _MicStep.noise => _noiseCard(context, useMidi),
        _MicStep.reference => _referenceCard(context, useMidi),
        _MicStep.done => _doneCard(context),
      },
    ];
  }

  Widget _intro(BuildContext context, Widget useMidi) {
    final t = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.mic_none, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 10),
                Expanded(child: Text('Why the microphone?', style: t.titleMedium)),
                HelpButton('mic'),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Without a MIDI keyboard, Stavelight listens to your piano to hear which note you play. '
              'Calibration checks it hears the right octave in your room.',
            ),
            const SizedBox(height: 8),
            const _Bullet(Icons.lock_outline, 'Audio is analyzed live on this phone. It is never recorded, saved or uploaded.'),
            const SizedBox(height: 8),
            Text('Before you start', style: t.titleSmall),
            for (final item in _checklist.keys)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _checklist[item],
                onChanged: (v) => setState(() => _checklist[item] = v ?? false),
                title: Text(item),
                controlAffinity: ListTileControlAffinity.leading,
              ),
            const SizedBox(height: 8),
            Semantics(
              hint: 'Your phone will ask for microphone permission',
              child: FilledButton.icon(onPressed: _startMic, icon: const Icon(Icons.mic), label: const Text('Start microphone check')),
            ),
            const SizedBox(height: 4),
            Text('Your phone will ask for microphone permission.', style: t.bodySmall, textAlign: TextAlign.center),
            const SizedBox(height: 4),
            Center(child: useMidi),
          ],
        ),
      ),
    );
  }

  Widget _noiseCard(BuildContext context, Widget useMidi) {
    final t = Theme.of(context).textTheme;
    final floor = _noiseFloor;
    final level = floor == null ? null : CalibrationMath.classifyNoise(floor);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Step 1 of 2 · Noise check', style: t.labelLarge),
            const SizedBox(height: 4),
            Text(floor == null ? 'Stay quiet for a moment' : 'Room measured', style: t.headlineSmall),
            const SizedBox(height: 8),
            if (floor == null) ...[
              const Text('Stavelight is measuring the background sound in your room. Don’t play yet.'),
              const SizedBox(height: 12),
              LinearProgressIndicator(value: _noiseProgress, semanticsLabel: 'Measuring room noise'),
            ] else ...[
              switch (level!) {
                NoiseLevel.quiet => const InfoBanner('Quiet room — good for detection.', icon: Icons.check_circle, color: SlColors.good),
                NoiseLevel.moderate => const InfoBanner(
                  'Some background noise. Detection should work; play each note firmly.',
                  icon: Icons.hearing,
                  color: SlColors.warn,
                ),
                NoiseLevel.noisy => const InfoBanner(
                  'Room is noisy — detection may be unreliable. Try a quieter spot, move the phone closer to the piano, or use MIDI.',
                  icon: Icons.warning_amber,
                  color: SlColors.bad,
                ),
              },
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  FilledButton(onPressed: _startReference, child: Text(level == NoiseLevel.noisy ? 'Continue anyway' : 'Continue')),
                  OutlinedButton(onPressed: _startNoise, child: const Text('Measure again')),
                  useMidi,
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _referenceCard(BuildContext context, Widget useMidi) {
    final t = Theme.of(context).textTheme;
    final expected = _refs[_refIndex];
    final r = _result;
    final children = <Widget>[
      Text('Step 2 of 2 · Reference notes', style: t.labelLarge),
      const SizedBox(height: 4),
      Text(_refIndex == 0 ? 'Play middle C (C4)' : 'Play C5 (one octave higher)', style: t.headlineSmall),
      const SizedBox(height: 4),
      Text(
        _refIndex == 0
            ? 'The C closest to the middle of the keyboard. Play it firmly, once, and let it ring.'
            : 'The next C up from middle C — eight white keys to the right. Play it firmly, once.',
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        children: [
          for (var i = 0; i < _refs.length; i++)
            Chip(
              avatar: Icon(
                _confirmed[i] ? Icons.check_circle : Icons.radio_button_unchecked,
                size: 18,
                color: _confirmed[i] ? SlColors.good : null,
              ),
              label: Text('${Pitch.name(_refs[i])}${_confirmed[i] ? ' confirmed' : ''}'),
            ),
        ],
      ),
      if (_notice != null) ...[const SizedBox(height: 8), InfoBanner(_notice!, icon: Icons.info_outline)],
      const SizedBox(height: 12),
    ];

    if (_listening) {
      children.add(
        Row(
          children: [
            const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 3)),
            const SizedBox(width: 12),
            Expanded(child: Text('Listening…', style: t.titleMedium)),
          ],
        ),
      );
    } else if (r != null) {
      children.add(Semantics(liveRegion: true, child: _resultView(context, r, expected)));
    }

    children.addAll([
      const Divider(height: 32),
      _Stepper(
        label: 'Adjust octave',
        value: CalibrationMath.signed(_draft.octaveOffset),
        unit: 'octave',
        onMinus: () => _adjustOctave(-1),
        onPlus: () => _adjustOctave(1),
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 12,
        runSpacing: 8,
        children: [
          OutlinedButton.icon(onPressed: _startReference, icon: const Icon(Icons.replay), label: const Text('Test again')),
          useMidi,
        ],
      ),
    ]);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
      ),
    );
  }

  Widget _resultView(BuildContext context, ReferenceCheck r, int expected) {
    final t = Theme.of(context).textTheme;
    final heard = r.heard;
    Widget heardLine() => Wrap(
      spacing: 12,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text('Heard ${Pitch.name(heard!)}', style: t.headlineSmall?.copyWith(fontWeight: FontWeight.w600)),
        Text('octave ${Pitch.octaveOf(heard)}', style: t.bodyMedium),
        ConfidenceBadge(r.confidence),
      ],
    );
    const tips = [
      _Bullet(Icons.touch_app_outlined, 'Play a single key firmly and let it ring.'),
      _Bullet(Icons.phone_android, 'Move the phone closer to the piano.'),
      _Bullet(Icons.volume_off_outlined, 'Reduce background noise (TV, fans, talking).'),
      _Bullet(Icons.do_not_touch_outlined, 'Keep your foot off the pedal.'),
    ];
    switch (r.outcome) {
      case ReferenceOutcome.match:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            heardLine(),
            const SizedBox(height: 8),
            Text('Is this the note you played?', style: t.titleMedium),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [FilledButton.icon(onPressed: _confirmYes, icon: const Icon(Icons.check), label: const Text('Yes'))],
            ),
          ],
        );
      case ReferenceOutcome.octaveOff:
        final change = r.suggestedOctaveChange;
        final above = r.octaveDelta > 0;
        final n = r.octaveDelta.abs();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            heardLine(),
            const SizedBox(height: 8),
            Text(
              'That’s ${n == 1 ? 'one octave' : '$n octaves'} ${above ? 'above' : 'below'} ${Pitch.name(expected)}. '
              'If you played ${Pitch.name(expected)}, the detector is hearing ${above ? 'an overtone' : 'a lower resonance'}. '
              'Correct it so a right note is never judged as the wrong octave.',
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                FilledButton(
                  onPressed: () => _adjustOctave(change),
                  child: Text('Apply correction (${CalibrationMath.semitoneLabel(change * 12)})'),
                ),
              ],
            ),
          ],
        );
      case ReferenceOutcome.wrongNote:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            heardLine(),
            const SizedBox(height: 8),
            Text(
              'That isn’t a C. Check that you played ${Pitch.name(expected)} and test again. '
              'If you did, your piano may be tuned away from A4 = ${_draft.a4Hz.round()} Hz — check the tuning reference below.',
            ),
          ],
        );
      case ReferenceOutcome.unclear:
      case ReferenceOutcome.noSignal:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text("Couldn't hear a clear note", style: t.headlineSmall?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(
              r.outcome == ReferenceOutcome.noSignal
                  ? 'Nothing was detected in 8 seconds.'
                  : heard == null
                  ? 'There was sound, but no single clear pitch.'
                  : 'Possibly ${Pitch.name(heard)}, but not confidently enough to count.',
            ),
            if (heard != null) ...[const SizedBox(height: 6), Align(alignment: Alignment.centerLeft, child: ConfidenceBadge(r.confidence))],
            const SizedBox(height: 8),
            ...tips,
          ],
        );
    }
  }

  Widget _doneCard(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final off = _app.micProfile.octaveOffset;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            const Icon(Icons.check_circle, size: 72, color: SlColors.good, semanticLabel: 'Success'),
            const SizedBox(height: 8),
            Text('Calibrated', style: t.headlineMedium?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text(
              'Middle C and C5 were heard and confirmed${off == 0 ? '' : ', with an octave correction of ${CalibrationMath.signed(off)}'}. '
              'The microphone is now your practice input.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 12,
              runSpacing: 8,
              children: [
                FilledButton(onPressed: () => Navigator.maybePop(context), child: const Text('Done')),
                OutlinedButton.icon(onPressed: _recalibrate, icon: const Icon(Icons.replay), label: const Text('Recalibrate')),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _tuningCard(BuildContext context, MicService? mic) {
    final t = Theme.of(context).textTheme;
    final f = mic?.lastFrame;
    final listening = mic?.isListening ?? false;
    String live = 'Play a note to see how close it is to the reference.';
    if (listening && f?.hz != null && f!.clarity >= 0.6) {
      final (n, cents) = CalibrationMath.nearest(f.hz!, a4: _draft.a4Hz);
      live = '${Pitch.name(_draft.correct(n))}: ${CalibrationMath.centsLabel(cents)}';
    } else if (!listening) {
      live = 'Start the microphone check to see live tuning.';
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Tuning reference: A4 = ${_draft.a4Hz.round()} Hz', style: t.titleSmall),
            Slider(
              min: 415,
              max: 466,
              divisions: 51,
              value: _draft.a4Hz.clamp(415, 466).toDouble(),
              label: '${_draft.a4Hz.round()} Hz',
              semanticFormatterCallback: (v) => 'A4 ${v.round()} hertz',
              onChanged: (v) => setState(() {
                _draft.a4Hz = v.roundToDouble();
                _dirty = true;
              }),
            ),
            Row(
              children: [
                Expanded(
                  child: Semantics(liveRegion: true, child: Text(live, style: t.bodyMedium)),
                ),
                TextButton(
                  onPressed: _draft.a4Hz == 440
                      ? null
                      : () => setState(() {
                          _draft.a4Hz = 440;
                          _dirty = true;
                        }),
                  child: const Text('Reset to 440'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text('Sensitivity: ${(_draft.sensitivity * 100).round()}%', style: t.titleSmall),
            Slider(
              min: 0,
              max: 1,
              divisions: 10,
              value: _draft.sensitivity.clamp(0.0, 1.0),
              label: '${(_draft.sensitivity * 100).round()}%',
              semanticFormatterCallback: (v) => 'Sensitivity ${(v * 100).round()} percent',
              onChanged: (v) => setState(() {
                _draft.sensitivity = v;
                _dirty = true;
              }),
            ),
            Text(
              'Higher hears quieter notes but may pick up noise. Changes apply immediately and are saved when calibration finishes.',
              style: t.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Widget _limitations(BuildContext context) => const Card(
    child: Padding(
      padding: EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Bullet(Icons.volume_up_outlined, 'Room noise, talking or music can hide or confuse notes.'),
          _Bullet(Icons.waves, 'Sustain pedal and long ringing notes blur into the next note.'),
          _Bullet(Icons.queue_music, 'Overlapping notes and chords: only one main pitch is heard at a time.'),
          _Bullet(Icons.graphic_eq, 'Instrument timbre (upright, grand, digital speakers) affects octave detection.'),
          _Bullet(Icons.height, 'Very low and very high notes are harder to detect reliably.'),
          _Bullet(Icons.piano, 'For precise feedback, use a MIDI keyboard.'),
        ],
      ),
    ),
  );
}
