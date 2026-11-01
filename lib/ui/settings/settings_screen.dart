import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/app_state.dart';
import '../../data/settings_repository.dart';
import '../calibration/calibration_screen.dart';
import '../calibration/input_test_screen.dart';
import '../onboarding/onboarding_screen.dart';
import '../theme.dart';
import '../widgets/common.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final s = app.settings;
    void set(void Function(AppSettings) f) => app.updateSettings(f);
    final mic = app.calibrations['mic'];
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.symmetric(horizontal: 16), children: [
          const SectionTitle('Input'),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.tune),
            title: const Text('Input & octave calibration'),
            subtitle: Text([
              app.midi.connected != null ? 'MIDI: ${app.midi.connected!.name}' : 'No MIDI keyboard connected',
              mic?.confirmed == true ? 'Microphone calibrated ${mic!.calibratedAt != null ? formatDate(mic.calibratedAt!) : ''}' : 'Microphone not calibrated',
            ].join('\n')),
            isThreeLine: true,
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const CalibrationScreen())),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.monitor_heart_outlined),
            title: const Text('Input diagnostics'),
            subtitle: const Text('See incoming notes without scoring'),
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const InputTestScreen(diagnostics: true))),
          ),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'midi', label: Text('Prefer MIDI')),
              ButtonSegment(value: 'mic', label: Text('Microphone')),
              ButtonSegment(value: 'none', label: Text('Ask / none')),
            ],
            selected: {s.preferredInput},
            onSelectionChanged: (v) => set((x) => x.preferredInput = v.first),
          ),
          const SectionTitle('Appearance'),
          SegmentedButton<ThemePref>(
            segments: const [
              ButtonSegment(value: ThemePref.system, label: Text('System')),
              ButtonSegment(value: ThemePref.light, label: Text('Light')),
              ButtonSegment(value: ThemePref.dark, label: Text('Dark')),
            ],
            selected: {s.theme},
            onSelectionChanged: (v) => set((x) => x.theme = v.first),
          ),
          SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('High contrast'), value: s.highContrast, onChanged: (v) => set((x) => x.highContrast = v)),
          SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Visual effects'), subtitle: const Text('Glow when a note is hit'), value: s.visualEffects, onChanged: (v) => set((x) => x.visualEffects = v)),
          const SectionTitle('Practice aids'),
          SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Note names'), value: s.noteNames, onChanged: (v) => set((x) => x.noteNames = v)),
          SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Octave numbers'), value: s.octaveLabels, onChanged: (v) => set((x) => x.octaveLabels = v)),
          SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Finger numbers (from the score)'), value: s.fingerNumbers, onChanged: (v) => set((x) => x.fingerNumbers = v)),
          SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Pedal lane'), secondary: const HelpButton('pedal'), value: s.pedalLane, onChanged: (v) => set((x) => x.pedalLane = v)),
          SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Haptic feedback on mistakes'), value: s.haptics, onChanged: (v) => set((x) => x.haptics = v)),
          SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Sound cue on mistakes'), value: s.audioCues, onChanged: (v) => set((x) => x.audioCues = v)),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Default count-in'),
            trailing: DropdownButton<int>(
              value: s.countInBeats,
              items: [for (final b in [0, 2, 3, 4, 6, 8]) DropdownMenuItem(value: b, child: Text(b == 0 ? 'Off' : '$b beats'))],
              onChanged: (v) => set((x) => x.countInBeats = v ?? 4),
            ),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Wait mode: offer Skip after'),
            trailing: DropdownButton<double>(
              value: s.waitTimeout,
              items: [for (final t in [3.0, 5.0, 8.0, 12.0, 20.0]) DropdownMenuItem(value: t, child: Text('${t.round()} s'))],
              onChanged: (v) => set((x) => x.waitTimeout = v ?? 8),
            ),
          ),
          SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Accent the first beat'), value: s.accentDownbeat, onChanged: (v) => set((x) => x.accentDownbeat = v)),
          _slider(context, 'Playback volume', s.playbackVolume, (v) => set((x) => x.playbackVolume = v)),
          _slider(context, 'Metronome volume', s.metronomeVolume, (v) => set((x) => x.metronomeVolume = v)),
          const SectionTitle('Goals'),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Daily practice goal'),
            subtitle: const Text('Optional. Shown in the library.'),
            trailing: DropdownButton<int>(
              value: s.dailyGoalMinutes,
              items: [for (final m in [0, 5, 10, 15, 20, 30, 45, 60]) DropdownMenuItem(value: m, child: Text(m == 0 ? 'None' : '$m min'))],
              onChanged: (v) => set((x) => x.dailyGoalMinutes = v ?? 0),
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Show practice streak'),
            subtitle: const Text('Counts days in a row with any practice. Off by default.'),
            value: s.streaksOptIn,
            onChanged: (v) => set((x) => x.streaksOptIn = v),
          ),
          const SectionTitle('Your data'),
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text('Imported files, scores and practice history are stored only on this device. '
                'Stavelight never records or uploads microphone audio, and recognition of scans happens on-device.'),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.ios_share),
            title: const Text('Export backup'),
            subtitle: const Text('A .zip of your files, scores, history and settings'),
            onTap: () => _export(context),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.delete_forever_outlined, color: Theme.of(context).colorScheme.error),
            title: Text('Delete all data', style: TextStyle(color: Theme.of(context).colorScheme.error)),
            subtitle: const Text('Removes every imported piece, history, calibration and setting'),
            onTap: () => _deleteAll(context),
          ),
          const SectionTitle('About'),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.school_outlined),
            title: const Text('Show the introduction again'),
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const OnboardingScreen(replay: true))),
          ),
          ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.help_outline), title: const Text('About scanned music'), onTap: () => showHelp(context, 'confidence')),
          ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.mic_none), title: const Text('About microphone listening'), onTap: () => showHelp(context, 'mic')),
          const SizedBox(height: 32),
        ]),
      ),
    );
  }

  Widget _slider(BuildContext context, String label, double v, ValueChanged<double> onChanged) => Row(children: [
        Expanded(child: Text(label)),
        SizedBox(width: 200, child: Slider(value: v, onChanged: onChanged, label: '${(v * 100).round()}%')),
      ]);

  Future<void> _export(BuildContext context) async {
    final app = context.read<AppState>();
    try {
      final bytes = await app.library.exportBackup();
      final dir = await getTemporaryDirectory();
      final stamp = DateTime.now().toIso8601String().substring(0, 10);
      final f = File('${dir.path}/stavelight-backup-$stamp.zip');
      await f.writeAsBytes(bytes, flush: true);
      await SharePlus.instance.share(ShareParams(files: [XFile(f.path, mimeType: 'application/zip')], subject: 'Stavelight backup'));
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Export failed: $e')));
      }
    }
  }

  Future<void> _deleteAll(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        icon: const Icon(Icons.warning_amber_rounded, color: SlColors.bad),
        title: const Text('Delete all data?'),
        content: const Text('Every imported piece, original file, edited score, practice session, calibration and setting will be permanently removed from this device. Consider exporting a backup first.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(c).colorScheme.error),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Delete everything'),
          ),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      await context.read<AppState>().deleteAllData();
      if (context.mounted) {
        Navigator.of(context).popUntil((r) => r.isFirst);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('All data deleted.')));
      }
    }
  }
}
