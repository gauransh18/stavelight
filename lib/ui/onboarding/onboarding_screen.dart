import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/app_state.dart';
import '../../core/model/session.dart';
import '../calibration/calibration_screen.dart';
import '../theme.dart';

/// Short, skippable introduction. Everything here can be changed later in Settings.
class OnboardingScreen extends StatefulWidget {
  final bool replay;
  const OnboardingScreen({super.key, this.replay = false});
  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _pc = PageController();
  int _page = 0;

  Future<void> _done({InputKind? calibrate}) async {
    final app = context.read<AppState>();
    if (calibrate != null) {
      await app.updateSettings((s) => s.preferredInput = calibrate == InputKind.mic ? 'mic' : 'midi');
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => CalibrationScreen(initialInput: calibrate)));
    }
    await app.updateSettings((s) => s.onboardingDone = true);
    if (widget.replay && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final pages = [
      _Page(
        icon: Icons.library_music_outlined,
        title: 'Practice the music you already have',
        body: 'Import your own sheet music — PDF, photos, MusicXML or MIDI. Stavelight turns it into notes you can check, '
            'then listens while you play and shows what went well.',
      ),
      _Page(
        icon: Icons.fact_check_outlined,
        title: 'You stay in control of the score',
        body: 'Notes read from scans are a draft. Anything uncertain is marked so you can fix it before practicing. '
            'Nothing is uploaded: files, recognition and history stay on this device.',
      ),
      _Page(
        icon: Icons.piano,
        title: 'How will you play?',
        body: 'A MIDI keyboard (USB or Bluetooth) gives the most precise feedback. The microphone works with an acoustic piano, one note at a time. '
            'A quick calibration makes sure the right octave is detected.',
        extra: Column(children: [
          FilledButton.icon(onPressed: () => _done(calibrate: InputKind.midi), icon: const Icon(Icons.cable), label: const Text('Set up a MIDI keyboard')),
          const SizedBox(height: 10),
          OutlinedButton.icon(onPressed: () => _done(calibrate: InputKind.mic), icon: const Icon(Icons.mic_none), label: const Text('Use the microphone')),
          const SizedBox(height: 10),
          TextButton(onPressed: () => _done(), child: const Text('Decide later')),
        ]),
      ),
    ];
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(onPressed: () => _done(), child: const Text('Skip')),
          ),
          Expanded(
            child: PageView(
              controller: _pc,
              onPageChanged: (i) => setState(() => _page = i),
              children: pages,
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(20),
            child: Row(children: [
              for (var i = 0; i < pages.length; i++)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.only(right: 6),
                  width: i == _page ? 22 : 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: i == _page ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              const Spacer(),
              if (_page < pages.length - 1)
                FilledButton(
                  onPressed: () => _pc.nextPage(duration: const Duration(milliseconds: 300), curve: Curves.easeOut),
                  child: Text('Next', style: t.labelLarge?.copyWith(color: Theme.of(context).colorScheme.onPrimary)),
                ),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _Page extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  final Widget? extra;
  const _Page({required this.icon, required this.title, required this.body, this.extra});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(color: SlColors.brass.withValues(alpha: 0.15), shape: BoxShape.circle),
              child: Icon(icon, size: 56, color: Theme.of(context).colorScheme.primary),
            ),
            const SizedBox(height: 28),
            Text(title, style: t.headlineSmall, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            Text(body, style: t.bodyLarge, textAlign: TextAlign.center),
            if (extra != null) ...[const SizedBox(height: 28), extra!],
          ]),
        ),
      ),
    );
  }
}
