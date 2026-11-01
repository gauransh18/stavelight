import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';

import '../../app/app_state.dart';
import '../../core/edit/score_editor.dart';
import '../../core/model/pitch.dart';
import '../../core/model/score.dart';
import '../../core/model/session.dart';
import '../../core/practice/practice_engine.dart';
import '../../core/practice/timeline.dart';
import '../render/staff_view.dart';
import '../theme.dart';
import '../widgets/common.dart';

const _eighth = kPpq ~/ 2;
const _durations = <(String, int)>[('Whole', 1920), ('Half', 960), ('Quarter', 480), ('Eighth', 240), ('16th', 120)];

/// Score review & correction editor: check recognized/imported notes, fix them, autosave.
class ReviewScreen extends StatefulWidget {
  const ReviewScreen({super.key, required this.pieceId, this.onPractice});
  final String pieceId;

  /// Opens practice for this piece. When null the Practice button is hidden.
  final VoidCallback? onPractice;

  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> with TickerProviderStateMixin, WidgetsBindingObserver {
  late final AppState _app;
  ScoreEditor? _editor;
  bool _loading = true;
  String? _error;
  List<File> _pages = const [];

  String? _noteId;
  int? _measure;
  String? _pedalId;

  Timer? _saveTimer;
  bool _dirty = false;
  Future<void> _saving = Future.value();
  bool _disposed = false;

  bool _issuesOpen = false;
  bool _showOriginal = false;

  Ticker? _ticker;
  PracticeEngine? _engine;
  PracticeTimeline? _timeline;
  Duration _lastElapsed = Duration.zero;
  double? _cursorTick;

  final _staffKey = GlobalKey();

  Score get _score => _editor!.score;

  @override
  void initState() {
    super.initState();
    _app = context.read<AppState>();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _stopPreview();
    _saveNow();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      if (_engine != null && mounted) setState(_stopPreview);
      _saveNow();
    }
  }

  Future<void> _load() async {
    try {
      final score = await _app.library.loadScore(widget.pieceId);
      if (!mounted) return;
      if (score == null) {
        setState(() {
          _loading = false;
          _error = 'This score could not be found. It may have been deleted.';
        });
        return;
      }
      List<File> pages = const [];
      if (score.origin == ScoreOrigin.omr) {
        try {
          pages = await _app.library.pageImages(widget.pieceId);
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() {
        _editor = ScoreEditor(score, onChanged: _onChanged);
        _pages = pages;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'This score couldn’t be opened ($e).';
      });
    }
  }

  // ---- Editing & autosave --------------------------------------------------------------------------

  void _onChanged(Score s) {
    _stopPreview();
    if (_noteId != null && _editor!.note(_noteId!) == null) _noteId = null;
    if (_measure != null && _measure! >= s.measures.length) _measure = null;
    if (_pedalId != null && !s.pedals.any((p) => p.id == _pedalId)) _pedalId = null;
    _dirty = true;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 600), _saveNow);
    if (!_disposed) setState(() {});
  }

  Future<void> _saveNow() {
    _saveTimer?.cancel();
    _saveTimer = null;
    final ed = _editor;
    if (ed == null || !_dirty) return _saving;
    _dirty = false;
    final json = ed.score.toJson();
    return _saving = _saving.then((_) async {
      try {
        await _app.library.saveScore(widget.pieceId, Score.fromJson(json));
        _app.libraryChanged();
      } catch (e) {
        _dirty = true;
        debugPrint('Autosave failed: $e');
      }
    });
  }

  void _edit(void Function(ScoreEditor e) f) {
    final ed = _editor;
    if (ed != null) f(ed);
  }

  void _appendMeasure() {
    _edit((e) => e.appendMeasure());
    _selectMeasure(_editor!.score.measures.length - 1);
  }

  // ---- Selection -------------------------------------------------------------------------------------

  ScoreNote? get _note => _noteId == null ? null : _editor?.note(_noteId!);
  PedalEvent? get _pedal {
    for (final p in _editor?.score.pedals ?? const <PedalEvent>[]) {
      if (p.id == _pedalId) return p;
    }
    return null;
  }

  void _selectNote(String id) => setState(() {
        _noteId = id;
        _measure = null;
        _pedalId = null;
      });
  void _selectMeasure(int i) => setState(() {
        _noteId = null;
        _measure = i;
        _pedalId = null;
      });
  void _selectPedal(String id) => setState(() {
        _noteId = null;
        _measure = null;
        _pedalId = id;
      });

  int? get _selectionTick => _note?.startTick ??
      _pedal?.tick ??
      (_measure != null && _measure! < _score.measures.length ? _score.measures[_measure!].startTick : null);

  int? get _selectionMeasure {
    final t = _note?.startTick ?? _pedal?.tick;
    if (t != null) return _score.measureIndexAt(t);
    return _measure;
  }

  /// Uncertain items in score order: (tick, kind 0=measure 1=note 2=pedal, id).
  List<(int, int, String)> _uncertainItems() {
    final s = _score;
    return [
      for (final m in s.measures)
        if (StaffLayout.isUncertainMeasure(m)) (m.startTick, 0, '${m.index}'),
      for (final n in s.notes)
        if (StaffLayout.isUncertainNote(n)) (n.startTick, 1, n.id),
      for (final p in s.pedals)
        if (StaffLayout.isUncertainPedal(p)) (p.tick, 2, p.id),
    ]..sort((a, b) => a.$1 != b.$1 ? a.$1 - b.$1 : a.$2 - b.$2);
  }

  void _nextUncertain() {
    final items = _uncertainItems();
    if (items.isEmpty) return;
    final current = items.indexWhere((i) =>
        (i.$2 == 0 && _measure != null && i.$3 == '$_measure') ||
        (i.$2 == 1 && i.$3 == _noteId) ||
        (i.$2 == 2 && i.$3 == _pedalId));
    var next = 0;
    if (current >= 0) {
      next = (current + 1) % items.length;
    } else {
      final t = _selectionTick;
      if (t != null) next = math.max(0, items.indexWhere((i) => i.$1 >= t));
    }
    final it = items[next];
    switch (it.$2) {
      case 0:
        _selectMeasure(int.parse(it.$3));
      case 1:
        _selectNote(it.$3);
      default:
        _selectPedal(it.$3);
    }
  }

  // ---- Preview playback ------------------------------------------------------------------------------

  Future<void> _togglePreview() async {
    if (_engine != null) {
      setState(_stopPreview);
      return;
    }
    if (_score.notes.isEmpty) {
      _snack('Nothing to play yet — add some notes first.');
      return;
    }
    try {
      await _app.audio.init();
    } catch (_) {}
    if (!mounted) return;
    final tl = PracticeTimeline.build(_score);
    final engine = PracticeEngine(tl, PracticeConfig(demo: true, countInBeats: 0, metronome: false),
        input: InputKind.none, sound: _app.audio);
    final mi = _selectionMeasure;
    if (mi != null && mi > 0 && mi < tl.measureCount) engine.seekMeasure(mi);
    engine.start();
    _lastElapsed = Duration.zero;
    _ticker = createTicker(_onTick)..start();
    setState(() {
      _engine = engine;
      _timeline = tl;
      _cursorTick = tl.tempoMap.tickAt(engine.position);
    });
    if (!_app.audio.available) _snack('Sound output isn’t available — showing the playback cursor only.');
  }

  void _onTick(Duration elapsed) {
    final e = _engine, tl = _timeline;
    if (e == null || tl == null) return;
    final dt = (elapsed - _lastElapsed).inMicroseconds / 1e6;
    _lastElapsed = elapsed;
    try {
      e.tick(dt.clamp(0.0, 0.1));
    } catch (err) {
      debugPrint('Preview stopped: $err');
      setState(_stopPreview);
      return;
    }
    if (e.state == EngineState.finished) {
      setState(_stopPreview);
      return;
    }
    setState(() => _cursorTick = tl.tempoMap.tickAt(e.position));
  }

  /// Stops playback. Callers inside build-phase-safe code wrap this in setState.
  void _stopPreview() {
    _ticker?.dispose();
    _ticker = null;
    try {
      _engine?.stop();
    } catch (_) {}
    _engine = null;
    _timeline = null;
    _cursorTick = null;
  }

  // ---- Practice gate ---------------------------------------------------------------------------------

  Future<void> _practice() async {
    final open = widget.onPractice;
    if (open == null) return;
    unawaited(_saveNow());
    final n = _score.uncertainCount;
    if (n > 0) {
      final go = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Some items are unchecked'),
          content: Text('$n ${n == 1 ? 'item hasn’t' : 'items haven’t'} been checked yet. '
              'Feedback for those notes may be wrong.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Review now')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Practice anyway')),
          ],
        ),
      );
      if (!mounted) return;
      if (go != true) {
        if (go == false) _nextUncertain();
        return;
      }
    }
    setState(_stopPreview);
    await _saveNow();
    open();
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  // ---- Dialogs ---------------------------------------------------------------------------------------

  Future<void> _rename() async {
    final title = TextEditingController(text: _score.title);
    final composer = TextEditingController(text: _score.composer ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Title and composer'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: title, autofocus: true, decoration: const InputDecoration(labelText: 'Title')),
            const SizedBox(height: 12),
            TextField(controller: composer, decoration: const InputDecoration(labelText: 'Composer (optional)')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok == true && mounted) {
      final t = title.text.trim().isEmpty ? _score.title : title.text.trim();
      final cmp = composer.text.trim();
      _edit((e) => e.setTitle(t, cmp.isEmpty ? null : cmp));
    }
    title.dispose();
    composer.dispose();
  }

  Future<void> _confirmVerifyAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Mark everything as reviewed?'),
        content: const Text('This tells Stavelight you have checked every note and measure against the original. '
            'Uncertainty markers are cleared and practice feedback will treat the score as correct.\n\n'
            'Pedal marks are not included — check those one by one.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Mark reviewed')),
        ],
      ),
    );
    if (ok == true && mounted) {
      _edit((e) => e.verifyAll());
      final left = _score.uncertainCount;
      _snack(left == 0 ? 'Marked as reviewed.' : 'Marked as reviewed. $left pedal ${left == 1 ? 'mark' : 'marks'} still unchecked.');
    }
  }

  Future<void> _settings() async {
    final s = _score;
    var bpm = s.tempos.isEmpty ? 100.0 : s.tempoMap.bpmAt(0);
    var range = (s.rangeLow, s.rangeHigh);
    var original = _showOriginal;
    const ranges = [('88 keys', 21, 108), ('76 keys', 28, 103), ('61 keys', 36, 96), ('49 keys', 36, 84)];
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: const Text('Score settings'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text('Starting tempo: ${bpm.round()} BPM')),
                const HelpButton('tempo'),
              ]),
              Slider(
                value: bpm.clamp(20, 300),
                min: 20,
                max: 300,
                divisions: 280,
                label: '${bpm.round()}',
                semanticFormatterCallback: (v) => '${v.round()} beats per minute',
                onChanged: (v) => set(() => bpm = v.roundToDouble()),
              ),
              const SizedBox(height: 8),
              const Text('Instrument range'),
              const SizedBox(height: 6),
              Wrap(spacing: 8, runSpacing: 4, children: [
                for (final r in ranges)
                  ChoiceChip(
                    label: Text('${r.$1} (${Pitch.name(r.$2)}–${Pitch.name(r.$3)})'),
                    selected: range == (r.$2, r.$3),
                    onSelected: (_) => set(() => range = (r.$2, r.$3)),
                  ),
              ]),
              if (s.origin == ScoreOrigin.omr && _pages.isNotEmpty)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Show original pages'),
                  value: original,
                  onChanged: (v) => set(() => original = v),
                ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Apply')),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    if ((bpm - (s.tempos.isEmpty ? 100.0 : s.tempoMap.bpmAt(0))).abs() >= 0.5) _edit((e) => e.setTempo(0, bpm));
    if (range != (_score.rangeLow, _score.rangeHigh)) _edit((e) => e.setRange(range.$1, range.$2));
    setState(() => _showOriginal = original);
  }

  Future<void> _timeSignatureDialog(int index) async {
    final cur = _score.measures[index].time;
    var beats = cur.beats, type = cur.beatType;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: const Row(children: [Expanded(child: Text('Time signature')), HelpButton('timesig')]),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Applies from this measure onwards.', style: Theme.of(c).textTheme.bodySmall),
            const SizedBox(height: 12),
            Row(children: [
              const Expanded(child: Text('Beats per measure')),
              DropdownButton<int>(
                value: beats.clamp(1, 12),
                items: [for (var b = 1; b <= 12; b++) DropdownMenuItem(value: b, child: Text('$b'))],
                onChanged: (v) => set(() => beats = v ?? beats),
              ),
            ]),
            const SizedBox(height: 8),
            const Text('Beat unit'),
            const SizedBox(height: 6),
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 2, label: Text('2 · half')),
                ButtonSegment(value: 4, label: Text('4 · quarter')),
                ButtonSegment(value: 8, label: Text('8 · eighth')),
              ],
              selected: {type},
              emptySelectionAllowed: true,
              onSelectionChanged: (v) => set(() => type = v.isEmpty ? type : v.first),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: Text('Set $beats/$type')),
          ],
        ),
      ),
    );
    if (ok == true && mounted) _edit((e) => e.setTimeSignature(index, TimeSignature(beats, type)));
  }

  Future<void> _keySignatureDialog(int index) async {
    final cur = _score.measures[index].key;
    final picked = await showDialog<int>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Row(children: [Expanded(child: Text('Key signature')), HelpButton('keysig')]),
        contentPadding: const EdgeInsets.symmetric(vertical: 8),
        content: SizedBox(
          width: 360,
          child: ListView(shrinkWrap: true, children: [
            for (var f = -7; f <= 7; f++)
              ListTile(
                selected: f == cur.fifths,
                title: Text(KeySignature(f, minor: cur.minor).label),
                subtitle: Text(f == 0 ? 'No sharps or flats' : '${f.abs()} ${f > 0 ? 'sharp' : 'flat'}${f.abs() == 1 ? '' : 's'}'),
                trailing: f == cur.fifths ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(c, f),
              ),
          ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel'))],
      ),
    );
    if (picked != null && picked != cur.fifths && mounted) {
      _edit((e) => e.setKeySignature(index, KeySignature(picked, minor: cur.minor)));
    }
  }

  // ---- Actions used by panels ------------------------------------------------------------------------

  void _addNote({Hand? hand}) {
    final ed = _editor!;
    final n = _note;
    String id;
    if (n != null) {
      final h = n.hand != Hand.unassigned ? n.hand : (n.staff == 2 ? Hand.left : Hand.right);
      id = ed.addNote(midi: n.midi, startTick: n.startTick + n.durationTicks, durationTicks: kPpq, hand: h);
    } else {
      final mi = _measure;
      if (mi == null || mi >= _score.measures.length) return;
      final m = _score.measures[mi];
      final h = hand ?? Hand.right;
      final staff = h == Hand.left ? 2 : 1;
      // Next free slot on that staff inside the measure, else the measure start.
      var start = m.startTick;
      for (final x in _score.notes) {
        if (x.staff == staff && x.startTick >= m.startTick && x.startTick < m.endTick && x.endTick > start) start = x.endTick;
      }
      if (start >= m.endTick) start = m.startTick;
      id = ed.addNote(midi: h == Hand.left ? 48 : 72, startTick: start, durationTicks: kPpq, hand: h);
    }
    _selectNote(id);
  }

  void _addPedal(PedalType type) {
    final t = _selectionTick;
    if (t == null) return;
    final id = _editor!.addPedal(t, type);
    _selectPedal(id);
  }

  // ---- Build -------------------------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(appBar: AppBar(), body: const Center(child: CircularProgressIndicator()));
    }
    if (_error != null || _editor == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Review')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.error_outline, size: 48, color: SlColors.bad),
              const SizedBox(height: 12),
              Text(_error ?? 'Something went wrong.', textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(onPressed: () => Navigator.maybePop(context), child: const Text('Go back')),
            ]),
          ),
        ),
      );
    }
    return Scaffold(
      appBar: _appBar(),
      body: SafeArea(
        top: false,
        child: LayoutBuilder(builder: (context, c) {
          final wide = c.maxWidth >= 840 || (c.maxWidth > c.maxHeight && c.maxWidth >= 600);
          // Stable per window size, so the staff doesn't resize when the panel content changes.
          final scale = c.maxHeight < 500 ? 0.8 : (c.maxWidth >= 840 ? 1.2 : 1.0);
          final header = ConstrainedBox(
            constraints: BoxConstraints(maxHeight: c.maxHeight * (wide ? 0.4 : 0.32)),
            child: SingleChildScrollView(child: _statusHeader()),
          );
          final staff = Column(children: [
            if (_showOriginal && _pages.isNotEmpty) SizedBox(height: math.min(170, c.maxHeight * 0.28), child: _original()),
            Expanded(child: _staff(scale)),
          ]);
          if (wide) {
            return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Expanded(child: Column(children: [header, const Divider(height: 1), Expanded(child: staff)])),
              const VerticalDivider(width: 1),
              SizedBox(width: math.min(380, c.maxWidth * 0.42), child: _panel()),
            ]);
          }
          return Column(children: [
            header,
            const Divider(height: 1),
            Expanded(child: staff),
            const Divider(height: 1),
            ConstrainedBox(constraints: BoxConstraints(maxHeight: c.maxHeight * 0.45), child: _panel()),
          ]);
        }),
      ),
    );
  }

  PreferredSizeWidget _appBar() {
    final ed = _editor!;
    final s = ed.score;
    final theme = Theme.of(context);
    return AppBar(
      titleSpacing: 0,
      title: Tooltip(
        message: 'Rename',
        child: Semantics(
          button: true,
          hint: 'Rename',
          child: InkWell(
            onTap: _rename,
            borderRadius: BorderRadius.circular(8),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  if (s.composer != null)
                    Text(s.composer!, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
                ]),
              ),
            ),
          ),
        ),
      ),
      actions: [
        IconButton(tooltip: 'Undo', icon: const Icon(Icons.undo), onPressed: ed.canUndo ? ed.undo : null),
        IconButton(tooltip: 'Redo', icon: const Icon(Icons.redo), onPressed: ed.canRedo ? ed.redo : null),
        IconButton(
          tooltip: _engine != null ? 'Stop preview' : 'Play preview',
          icon: Icon(_engine != null ? Icons.stop_circle_outlined : Icons.play_circle_outline),
          onPressed: _togglePreview,
        ),
        PopupMenuButton<String>(
          tooltip: 'More',
          onSelected: (v) => switch (v) {
            'verify' => _confirmVerifyAll(),
            'settings' => _settings(),
            'append' => _appendMeasure(),
            _ => null,
          },
          itemBuilder: (c) => const [
            PopupMenuItem(value: 'verify', child: ListTile(leading: Icon(Icons.done_all), title: Text('Mark everything as reviewed'))),
            PopupMenuItem(value: 'append', child: ListTile(leading: Icon(Icons.add_box_outlined), title: Text('Add measure at end'))),
            PopupMenuItem(value: 'settings', child: ListTile(leading: Icon(Icons.tune), title: Text('Score settings'))),
          ],
        ),
      ],
    );
  }

  (IconData, Color, String) _status() {
    final s = _score;
    final n = s.uncertainCount;
    final need = n == 1 ? '1 item needs review' : '$n items need review';
    if (s.review == ReviewState.verified) {
      return n == 0
          ? (Icons.verified, SlColors.good, 'Verified')
          : (Icons.verified_outlined, SlColors.warn, 'Reviewed — $n ${n == 1 ? 'item' : 'items'} still unchecked');
    }
    final source = switch (s.origin) {
      ScoreOrigin.omr => 'Recognized from scan',
      ScoreOrigin.midi => 'Imported from MIDI',
      ScoreOrigin.musicxml => 'Imported from MusicXML',
      ScoreOrigin.manual => 'Entered by hand',
    };
    if (n > 0) return (Icons.help_outline, SlColors.warn, '$source — $need');
    if (s.origin == ScoreOrigin.omr) return (Icons.document_scanner_outlined, SlColors.seed, '$source — please check it against the original');
    return (Icons.check_circle_outline, SlColors.seed, source);
  }

  Widget _statusHeader() {
    final s = _score;
    final theme = Theme.of(context);
    final (icon, color, text) = _status();
    final n = s.uncertainCount;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Icon(icon, color: color),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: theme.textTheme.titleSmall)),
          if (s.issues.isNotEmpty)
            IconButton(
              tooltip: _issuesOpen ? 'Hide import notes' : 'Show ${s.issues.length} import ${s.issues.length == 1 ? 'note' : 'notes'}',
              onPressed: () => setState(() => _issuesOpen = !_issuesOpen),
              icon: Badge(
                label: Text('${s.issues.length}'),
                child: Icon(_issuesOpen ? Icons.expand_less : Icons.list_alt),
              ),
            ),
          const HelpButton('confidence'),
        ]),
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
            if (n > 0)
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(minimumSize: const Size(48, 44), padding: const EdgeInsets.symmetric(horizontal: 14)),
                onPressed: _nextUncertain,
                icon: const Icon(Icons.skip_next),
                label: const Text('Next uncertain'),
              ),
            if (s.origin == ScoreOrigin.omr && _pages.isNotEmpty)
              FilterChip(
                avatar: const Icon(Icons.image_outlined, size: 18),
                label: const Text('Show original'),
                selected: _showOriginal,
                onSelected: (v) => setState(() => _showOriginal = v),
              ),
            if (widget.onPractice != null)
              FilledButton.icon(
                style: FilledButton.styleFrom(minimumSize: const Size(48, 44), padding: const EdgeInsets.symmetric(horizontal: 16)),
                onPressed: _practice,
                icon: const Icon(Icons.piano),
                label: const Text('Practice'),
              ),
          ]),
        ),
        if (_issuesOpen)
          for (final issue in s.issues)
            ListTile(
              dense: true,
              contentPadding: const EdgeInsets.only(left: 4, right: 8),
              leading: Icon(
                switch (issue.severity) { 'error' => Icons.error_outline, 'info' => Icons.info_outline, _ => Icons.warning_amber },
                color: switch (issue.severity) { 'error' => SlColors.bad, 'info' => theme.colorScheme.primary, _ => SlColors.warn },
              ),
              title: Text(issue.message),
              subtitle: issue.measureIndex != null && issue.measureIndex! < s.measures.length
                  ? Text('Measure ${s.measures[issue.measureIndex!].number} — tap to show')
                  : null,
              onTap: issue.measureIndex != null && issue.measureIndex! < s.measures.length
                  ? () => _selectMeasure(issue.measureIndex!)
                  : null,
            ),
      ]),
    );
  }

  Widget _staff(double scale) {
    final s = _score;
    final view = StaffView(
      key: _staffKey,
      score: s,
      selectedNoteId: _noteId,
      selectedMeasure: _measure,
      selectedPedalId: _pedalId,
      onNoteTap: _selectNote,
      onMeasureTap: _selectMeasure,
      onPedalTap: _selectPedal,
      cursorTick: _cursorTick,
      scale: scale,
    );
    if (s.notes.isNotEmpty) return view;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        child: InfoBanner(s.measures.isEmpty
            ? 'No measures yet — use “Add measure at end” in the menu.'
            : 'No notes yet — select a measure and tap Add note.'),
      ),
      Expanded(child: view),
    ]);
  }

  Widget _original() {
    final mi = _selectionMeasure;
    final m = mi != null && mi < _score.measures.length ? _score.measures[mi] : null;
    final page = (m?.page ?? 0).clamp(0, _pages.length - 1);
    final file = _pages[page];
    final theme = Theme.of(context);
    Widget image = Image.file(file, errorBuilder: (c, e, st) => const Center(child: Text('Page image unavailable')));
    String caption;
    if (m != null && m.x0 != null && m.x1 != null && m.y0 != null && m.y1 != null) {
      final x0 = (m.x0! - 0.01).clamp(0.0, 1.0), x1 = (m.x1! + 0.01).clamp(0.0, 1.0);
      final y0 = (m.y0! - 0.02).clamp(0.0, 1.0), y1 = (m.y1! + 0.02).clamp(0.0, 1.0);
      final wf = (x1 - x0).clamp(0.02, 1.0), hf = (y1 - y0).clamp(0.02, 1.0);
      double align(double start, double f) => f >= 1 ? 0 : (2 * start / (1 - f) - 1).clamp(-1.0, 1.0);
      image = ClipRect(child: Align(alignment: Alignment(align(x0, wf), align(y0, hf)), widthFactor: wf, heightFactor: hf, child: image));
      caption = 'Measure ${m.number} on page ${page + 1}';
    } else {
      image = Stack(children: [
        image,
        if (m != null && m.x0 != null && m.x1 != null)
          Positioned.fill(child: CustomPaint(painter: _RegionOutline(m.x0!, m.x1!, m.y0 ?? 0, m.y1 ?? 1))),
      ]);
      caption = m == null
          ? 'Page ${page + 1} — select a measure to find it'
          : m.x0 != null && m.x1 != null
              ? 'Measure ${m.number} is in the highlighted area of page ${page + 1}'
              : 'Page ${page + 1} — position of measure ${m.number} not recorded';
    }
    return Semantics(
      label: 'Original scan. $caption',
      image: true,
      child: Container(
        color: theme.colorScheme.surfaceContainerHighest,
        padding: const EdgeInsets.all(6),
        child: Column(children: [
          Expanded(child: FittedBox(fit: BoxFit.contain, child: image)),
          const SizedBox(height: 4),
          Text(caption, style: theme.textTheme.labelSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
        ]),
      ),
    );
  }

  Widget _panel() {
    final theme = Theme.of(context);
    final note = _note, pedal = _pedal;
    final Widget content;
    if (note != null) {
      content = _notePanel(note);
    } else if (pedal != null) {
      content = _pedalPanel(pedal);
    } else if (_measure != null && _measure! < _score.measures.length) {
      content = _measurePanel(_measure!);
    } else {
      content = _emptyPanel();
    }
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(12, 10, 12, 16), child: content),
    );
  }

  Widget _emptyPanel() {
    final s = _score;
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(
        s.notes.isEmpty
            ? 'No notes yet — select a measure and tap Add note.'
            : 'Tap a note, a measure number or a pedal mark to check or correct it.',
        style: theme.textTheme.bodyLarge,
      ),
      const SizedBox(height: 10),
      Wrap(spacing: 8, runSpacing: 8, children: [
        if (s.uncertainCount > 0)
          FilledButton.tonalIcon(onPressed: _nextUncertain, icon: const Icon(Icons.skip_next), label: const Text('Go to first uncertain')),
        OutlinedButton.icon(onPressed: _appendMeasure, icon: const Icon(Icons.add_box_outlined), label: const Text('Add measure at end')),
      ]),
    ]);
  }

  Widget _group(String label, List<Widget> children, {Widget? trailing}) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(label, style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant))),
          ?trailing,
        ]),
        const SizedBox(height: 6),
        Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: children),
      ]),
    );
  }

  Widget _tool(String tooltip, String label, VoidCallback? onPressed, {IconData? icon}) => Tooltip(
        message: tooltip,
        child: icon == null
            ? OutlinedButton(onPressed: onPressed, child: Text(label))
            : OutlinedButton.icon(onPressed: onPressed, icon: Icon(icon), label: Text(label)),
      );

  String _beats(int ticks) {
    final b = ticks / kPpq;
    final txt = b == b.roundToDouble() ? b.toStringAsFixed(0) : b.toStringAsFixed(2).replaceFirst(RegExp(r'0$'), '');
    return '$txt ${b == 1 ? 'beat' : 'beats'}';
  }

  Widget _notePanel(ScoreNote n) {
    final theme = Theme.of(context);
    final s = _score;
    final mi = s.measureIndexAt(n.startTick);
    final m = mi < s.measures.length ? s.measures[mi] : null;
    final key = m?.key ?? const KeySignature(0);
    final sp = StaffLayout.spell(n.midi, key, accidental: n.accidental);
    final (base, dots) = StaffLayout.noteValue(n.durationTicks, n.dots);
    final dotted = dots > 0;
    final hold = n.holdTicks;
    final holdSame = hold == null || hold == n.durationTicks;
    final id = n.id;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: 10, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
        HandBadge(n.hand, size: 26),
        Semantics(label: 'Selected note ${sp.spoken}', excludeSemantics: true, child: Text(sp.label, style: theme.textTheme.headlineSmall)),
        if (m != null) Text('Measure ${m.number}', style: theme.textTheme.bodyMedium),
        if (s.origin == ScoreOrigin.omr || n.verified || StaffLayout.isUncertainNote(n))
          ConfidenceChip(confidence: n.confidence, verified: n.verified),
      ]),
      if (n.flags.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text('Flagged: ${n.flags.join(', ')}', style: theme.textTheme.bodyMedium?.copyWith(color: SlColors.warn)),
        ),
      _group('Pitch', [
        _tool('Semitone down', 'Semitone', () => _edit((e) => e.transposeSemitones(id, -1)), icon: Icons.arrow_downward),
        _tool('Semitone up', 'Semitone', () => _edit((e) => e.transposeSemitones(id, 1)), icon: Icons.arrow_upward),
        _tool('Octave down', 'Octave', n.midi - 12 >= 0 ? () => _edit((e) => e.shiftOctave(id, -1)) : null, icon: Icons.keyboard_double_arrow_down),
        _tool('Octave up', 'Octave', n.midi + 12 <= 127 ? () => _edit((e) => e.shiftOctave(id, 1)) : null, icon: Icons.keyboard_double_arrow_up),
      ]),
      _group('Accidental', [
        for (final (alter, sym, name) in const [(-1, '♭', 'Flat'), (0, '♮', 'Natural'), (1, '♯', 'Sharp')])
          Tooltip(
            message: name,
            child: ChoiceChip(
              label: Text(sym, style: const TextStyle(fontSize: 20)),
              selected: n.accidental == alter,
              onSelected: (_) => _edit((e) => e.setAccidental(id, alter, preferFlatSpelling: key.prefersFlats)),
            ),
          ),
      ]),
      _group('Written length (notation)', [
        for (final (name, ticks) in _durations)
          ChoiceChip(
            label: Text(name),
            selected: base == ticks,
            onSelected: (_) => _edit((e) => e.setDuration(id, dotted ? ticks * 3 ~/ 2 : ticks, dots: dotted ? 1 : 0)),
          ),
        FilterChip(
          label: const Text('Dotted'),
          selected: dotted,
          onSelected: (v) => _edit((e) => e.setDuration(id, v ? base * 3 ~/ 2 : base, dots: v ? 1 : 0)),
        ),
      ], trailing: const HelpButton('duration')),
      Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
          decoration: BoxDecoration(
            border: Border.all(color: theme.colorScheme.outlineVariant),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(children: [
            const Icon(Icons.touch_app_outlined, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(holdSame
                  ? 'Key held: same as written'
                  : 'Key held: ${_beats(hold)} ${n.tieStart ? '(through the tie)' : '(from the recording)'}'),
            ),
            if (!holdSame && !n.tieStart) TextButton(onPressed: () => _edit((e) => e.setHold(id, null)), child: const Text('Match written')),
          ]),
        ),
      ),
      _group('Voice and hand', [
        SegmentedButton<int>(
          segments: const [ButtonSegment(value: 1, label: Text('Voice 1')), ButtonSegment(value: 2, label: Text('Voice 2'))],
          selected: {if (n.voice == 1 || n.voice == 2) n.voice},
          emptySelectionAllowed: true,
          showSelectedIcon: false,
          onSelectionChanged: (v) {
            if (v.isNotEmpty) _edit((e) => e.setVoice(id, v.first));
          },
        ),
        SegmentedButton<Hand>(
          segments: const [
            ButtonSegment(value: Hand.right, label: Text('R'), tooltip: 'Right hand'),
            ButtonSegment(value: Hand.left, label: Text('L'), tooltip: 'Left hand'),
          ],
          selected: {if (n.hand != Hand.unassigned) n.hand},
          emptySelectionAllowed: true,
          onSelectionChanged: (v) {
            if (v.isNotEmpty) _edit((e) => e.setHand(id, v.first));
          },
        ),
      ]),
      _group('Position', [
        _tool('Move earlier by an eighth', 'Earlier', n.startTick > 0 ? () => _edit((e) => e.moveNote(id, n.startTick - _eighth)) : null, icon: Icons.chevron_left),
        _tool('Move later by an eighth', 'Later', () => _edit((e) => e.moveNote(id, n.startTick + _eighth)), icon: Icons.chevron_right),
      ]),
      _group('Actions', [
        FilledButton.tonalIcon(
          onPressed: n.verified ? null : () => _edit((e) => e.verifyNote(id)),
          icon: Icon(n.verified ? Icons.verified : Icons.check),
          label: Text(n.verified ? 'Checked' : 'Mark as checked'),
        ),
        _tool('Add a quarter note after this one', 'Add note', () => _addNote(), icon: Icons.add),
        _tool('Add pedal down at this note', 'Pedal down', () => _addPedal(PedalType.down), icon: Icons.south),
        _tool('Add pedal up at this note', 'Pedal up', () => _addPedal(PedalType.up), icon: Icons.north),
        Tooltip(
          message: 'Delete note',
          child: TextButton.icon(
            style: TextButton.styleFrom(foregroundColor: SlColors.bad),
            onPressed: () {
              _edit((e) => e.deleteNote(id));
              if (mi < _score.measures.length) _selectMeasure(mi);
            },
            icon: const Icon(Icons.delete_outline),
            label: const Text('Delete'),
          ),
        ),
      ], trailing: const HelpButton('pedal')),
    ]);
  }

  Widget _measurePanel(int i) {
    final theme = Theme.of(context);
    final s = _score;
    final m = s.measures[i];
    final mid = m.startTick + ((m.lengthTicks / 2) / _eighth).round() * _eighth;
    final canSplit = mid > m.startTick && mid < m.endTick;
    final last = i == s.measures.length - 1;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: 10, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Text('Measure ${m.number}', style: theme.textTheme.headlineSmall),
        Chip(label: Text(m.time.label), visualDensity: VisualDensity.compact),
        Chip(label: Text(m.key.label), visualDensity: VisualDensity.compact),
        if (m.pickup) const Chip(label: Text('Pickup'), visualDensity: VisualDensity.compact),
        ConfidenceChip(confidence: m.confidence, verified: m.verified),
      ]),
      if (m.flags.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text('Flagged: ${m.flags.join(', ')}', style: theme.textTheme.bodyMedium?.copyWith(color: SlColors.warn)),
        ),
      _group('Check', [
        FilledButton.tonalIcon(
          onPressed: m.verified ? null : () => _edit((e) => e.verifyMeasure(i)),
          icon: Icon(m.verified ? Icons.verified : Icons.check),
          label: Text(m.verified ? 'Measure checked' : 'Mark measure as checked'),
        ),
      ]),
      _group('Add', [
        _tool('Add a right-hand note', 'Note (R)', () => _addNote(hand: Hand.right), icon: Icons.add),
        _tool('Add a left-hand note', 'Note (L)', () => _addNote(hand: Hand.left), icon: Icons.add),
        _tool('Add pedal down at the start of this measure', 'Pedal down', () => _addPedal(PedalType.down), icon: Icons.south),
        _tool('Add pedal up at the start of this measure', 'Pedal up', () => _addPedal(PedalType.up), icon: Icons.north),
        if (last) _tool('Add a measure after this one', 'Measure at end', _appendMeasure, icon: Icons.add_box_outlined),
      ], trailing: const HelpButton('pedal')),
      _group('Barline and length', [
        _tool('Move the end barline earlier by an eighth', 'Barline', () => _edit((e) => e.adjustMeasureLength(i, -_eighth)), icon: Icons.west),
        _tool('Move the end barline later by an eighth', 'Barline', () => _edit((e) => e.adjustMeasureLength(i, _eighth)), icon: Icons.east),
        _tool('Split this measure in the middle', 'Split', canSplit ? () => _edit((e) => e.splitMeasure(i, mid)) : null, icon: Icons.call_split),
        _tool('Merge with the next measure', 'Merge with next', last ? null : () => _edit((e) => e.mergeWithNext(i)), icon: Icons.merge),
      ]),
      _group('From this measure on', [
        _tool('Change time signature from here', 'Time ${m.time.label}', () => _timeSignatureDialog(i), icon: Icons.av_timer),
        _tool('Change key signature from here', 'Key', () => _keySignatureDialog(i), icon: Icons.tag),
      ], trailing: const HelpButton('keysig')),
      _group('Hands for all notes in this measure', [
        _tool('Assign every note to the right hand', 'All R', () => _edit((e) => e.setHandForMeasure(i, Hand.right))),
        _tool('Assign every note to the left hand', 'All L', () => _edit((e) => e.setHandForMeasure(i, Hand.left))),
        _tool('Treble staff right hand, bass staff left hand', 'By staff', () => _edit((e) {
              e.setHandForMeasure(i, Hand.right, staff: 1);
              e.setHandForMeasure(i, Hand.left, staff: 2);
            })),
      ], trailing: const HelpButton('hands')),
    ]);
  }

  Widget _pedalPanel(PedalEvent p) {
    final theme = Theme.of(context);
    final s = _score;
    final mi = s.measureIndexAt(p.tick);
    final source = switch (p.source) {
      'midi' => 'From the MIDI file',
      'musicxml' => 'From the MusicXML file',
      'omr' => 'Recognized from scan (candidate)',
      _ => 'Added by you',
    };
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: 10, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Text(p.type == PedalType.down ? 'Pedal down' : 'Pedal up', style: theme.textTheme.headlineSmall),
        if (mi < s.measures.length) Text('Measure ${s.measures[mi].number}', style: theme.textTheme.bodyMedium),
        ConfidenceChip(confidence: p.confidence, verified: p.verified),
        const HelpButton('pedal'),
      ]),
      Padding(padding: const EdgeInsets.only(top: 4), child: Text(source, style: theme.textTheme.bodySmall)),
      _group('Type', [
        SegmentedButton<PedalType>(
          segments: const [
            ButtonSegment(value: PedalType.down, label: Text('Down (Ped.)')),
            ButtonSegment(value: PedalType.up, label: Text('Up (release)')),
          ],
          selected: {p.type},
          onSelectionChanged: (v) => _edit((e) => e.setPedalType(p.id, v.first)),
        ),
      ]),
      _group('Position', [
        _tool('Move pedal earlier by an eighth', 'Earlier', p.tick > 0 ? () => _edit((e) => e.movePedal(p.id, p.tick - _eighth)) : null, icon: Icons.chevron_left),
        _tool('Move pedal later by an eighth', 'Later', () => _edit((e) => e.movePedal(p.id, p.tick + _eighth)), icon: Icons.chevron_right),
      ]),
      _group('Actions', [
        FilledButton.tonalIcon(
          onPressed: p.verified ? null : () => _edit((e) => e.verifyPedal(p.id)),
          icon: Icon(p.verified ? Icons.verified : Icons.check),
          label: Text(p.verified ? 'Checked' : 'Mark as checked'),
        ),
        Tooltip(
          message: 'Delete pedal mark',
          child: TextButton.icon(
            style: TextButton.styleFrom(foregroundColor: SlColors.bad),
            onPressed: () {
              _edit((e) => e.deletePedal(p.id));
              if (mi < _score.measures.length) _selectMeasure(mi);
            },
            icon: const Icon(Icons.delete_outline),
            label: const Text('Delete'),
          ),
        ),
      ]),
    ]);
  }
}

/// Outlines a normalized region on a page image when an exact crop isn't possible.
class _RegionOutline extends CustomPainter {
  final double x0, x1, y0, y1;
  _RegionOutline(this.x0, this.x1, this.y0, this.y1);

  @override
  void paint(Canvas canvas, Size size) {
    final r = Rect.fromLTRB(x0 * size.width, y0 * size.height, x1 * size.width, y1 * size.height);
    canvas.drawRect(r, Paint()..color = SlColors.brass.withValues(alpha: 0.15));
    canvas.drawRect(r, Paint()
      ..color = SlColors.brass
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(2, size.width / 300));
  }

  @override
  bool shouldRepaint(_RegionOutline old) => old.x0 != x0 || old.x1 != x1 || old.y0 != y0 || old.y1 != y1;
}
