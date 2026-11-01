import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../../core/import/import_types.dart';
import '../../core/model/pitch.dart';
import '../../core/model/score.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'import_flow.dart';
import 'isolate_jobs.dart';

class OmrOutcome {
  final Score? score;
  final bool editPages;
  const OmrOutcome.score(Score this.score) : editPages = false;
  const OmrOutcome.editPages()
      : score = null,
        editPages = true;
}

/// Confirm clef/key/time (never guessed silently), run on-device recognition, and report per page.
class OmrRunScreen extends StatefulWidget {
  final List<img.Image> pages;
  final String title;
  const OmrRunScreen({super.key, required this.pages, required this.title});
  @override
  State<OmrRunScreen> createState() => _OmrRunScreenState();
}

class _OmrRunScreenState extends State<OmrRunScreen> {
  OmrSettings _s = const OmrSettings();
  bool _running = false;
  OmrResult? _result;
  String? _error;

  Future<void> _run() async {
    setState(() {
      _running = true;
      _error = null;
      _result = null;
    });
    try {
      final r = await recognize(widget.pages, _s, widget.title);
      if (mounted) setState(() => _result = r);
    } catch (e) {
      if (mounted) setState(() => _error = 'Recognition failed unexpectedly ($e). You can adjust the pages or enter notes manually.');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final r = _result;
    return Scaffold(
      appBar: AppBar(title: Text(r == null ? 'Recognition settings' : 'Recognition result')),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.all(16), children: [
          if (r == null) ..._settings(t) else ..._report(r, t),
          if (_error != null) ...[const SizedBox(height: 12), InfoBanner(_error!, icon: Icons.error_outline, color: SlColors.bad)],
        ]),
      ),
    );
  }

  List<Widget> _settings(TextTheme t) => [
        const InfoBanner(
          'Notes are recognized on this device — nothing is uploaded. Recognition is a best-effort draft: '
          'you will review the result and correct anything marked uncertain before practicing.',
          icon: Icons.lock_outline,
        ),
        const SizedBox(height: 8),
        Text('Tell Stavelight what the music uses. These are not guessed from the page.', style: t.bodyMedium),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Piano grand staff'),
          subtitle: const Text('Two staves joined together (right hand above, left hand below)'),
          value: _s.grandStaff,
          onChanged: (v) => setState(() => _s = _s.copyWith(grandStaff: v)),
        ),
        if (_s.grandStaff)
          Row(children: [
            Expanded(child: _clefPicker('Upper staff', _s.upperClef, (c) => _s = _s.copyWith(upperClef: c))),
            const SizedBox(width: 12),
            Expanded(child: _clefPicker('Lower staff', _s.lowerClef, (c) => _s = _s.copyWith(lowerClef: c))),
          ])
        else
          _clefPicker('Clef', _s.singleClef, (c) => _s = _s.copyWith(singleClef: c)),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: DropdownButtonFormField<int>(
              initialValue: _s.key.fifths,
              decoration: const InputDecoration(labelText: 'Key signature', border: OutlineInputBorder()),
              items: [
                for (var f = -7; f <= 7; f++)
                  DropdownMenuItem(value: f, child: Text('${f == 0 ? 'No' : f.abs()} ${f < 0 ? '♭' : f > 0 ? '♯' : 'sharps/flats'} · ${KeySignature(f).label}')),
              ],
              onChanged: (v) => setState(() => _s = _s.copyWith(key: KeySignature(v ?? 0))),
            ),
          ),
          const HelpButton('keysig'),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: DropdownButtonFormField<String>(
              initialValue: _s.time.label,
              decoration: const InputDecoration(labelText: 'Time signature', border: OutlineInputBorder()),
              items: [for (final l in ['2/4', '3/4', '4/4', '2/2', '3/8', '6/8', '9/8', '12/8', '5/4']) DropdownMenuItem(value: l, child: Text(l))],
              onChanged: (v) {
                final p = (v ?? '4/4').split('/');
                setState(() => _s = _s.copyWith(time: TimeSignature(int.parse(p[0]), int.parse(p[1]))));
              },
            ),
          ),
          const HelpButton('timesig'),
        ]),
        const SizedBox(height: 12),
        Text('Tempo: ${_s.bpm.round()} beats per minute', style: t.bodyMedium),
        Slider(value: _s.bpm, min: 40, max: 200, divisions: 160, label: '${_s.bpm.round()}', onChanged: (v) => setState(() => _s = _s.copyWith(bpm: v))),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: _running ? null : _run,
          icon: _running ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.auto_fix_high),
          label: Text(_running ? 'Recognizing ${widget.pages.length} page(s)…' : 'Recognize notes'),
        ),
        const SizedBox(height: 8),
        OutlinedButton(onPressed: _running ? null : () => Navigator.pop(context, const OmrOutcome.editPages()), child: const Text('Back to pages')),
      ];

  Widget _clefPicker(String label, ClefKind value, void Function(ClefKind) set) => DropdownButtonFormField<ClefKind>(
        initialValue: value,
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
        items: const [
          DropdownMenuItem(value: ClefKind.treble, child: Text('Treble (G) clef')),
          DropdownMenuItem(value: ClefKind.bass, child: Text('Bass (F) clef')),
        ],
        onChanged: (v) => setState(() => set(v ?? value)),
      );

  List<Widget> _report(OmrResult r, TextTheme t) {
    final notes = r.score.notes.length;
    final uncertain = r.score.uncertainCount;
    return [
      if (r.anyUsable)
        InfoBanner(
          'Found $notes notes in ${r.score.measures.length} measures. $uncertain item(s) are marked uncertain. '
          'Everything is “recognized”, not verified — check it in the next step.',
          icon: Icons.fact_check_outlined,
          color: uncertain > 0 ? SlColors.warn : SlColors.seed,
        )
      else
        const InfoBanner(
          'No page could be read reliably, so Stavelight won’t create practice data from it. '
          'Fix the pages (see below) or enter the notes yourself.',
          icon: Icons.error_outline,
          color: SlColors.bad,
        ),
      const SectionTitle('Pages'),
      for (final p in r.pages)
        Card(
          child: ListTile(
            leading: Icon(p.ok ? Icons.check_circle_outline : Icons.error_outline, color: p.ok ? SlColors.good : SlColors.bad),
            title: Text('Page ${p.pageIndex + 1}: ${p.ok ? '${p.notesFound} notes, ${p.stavesFound} staves' : 'not readable'}'),
            subtitle: Text([
              if (p.ok) 'Average confidence ${(p.meanConfidence * 100).round()}%',
              if (p.failureReason != null) p.failureReason!,
              ...p.hints,
            ].join('\n')),
            isThreeLine: true,
          ),
        ),
      if (r.score.issues.isNotEmpty) ...[
        const SectionTitle('Things to check'),
        for (final i in r.score.issues.take(12))
          Padding(padding: const EdgeInsets.only(bottom: 6), child: Text('• ${i.message}${i.measureIndex != null && !i.message.toLowerCase().contains('measure') ? ' (measure ${i.measureIndex! + 1})' : ''}')),
      ],
      const SizedBox(height: 16),
      if (r.anyUsable) FilledButton(onPressed: () => Navigator.pop(context, OmrOutcome.score(r.score)), child: const Text('Review the score')),
      const SizedBox(height: 8),
      OutlinedButton(onPressed: () => Navigator.pop(context, const OmrOutcome.editPages()), child: const Text('Adjust pages and try again')),
      const SizedBox(height: 8),
      OutlinedButton(onPressed: () => setState(() => _result = null), child: const Text('Change clef, key or time')),
      const SizedBox(height: 8),
      TextButton(
        onPressed: () => Navigator.pop(context, OmrOutcome.score(emptyScore(widget.title, _s))),
        child: const Text('Enter notes manually instead'),
      ),
    ];
  }
}
