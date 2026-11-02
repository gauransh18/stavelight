import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/app_state.dart';
import '../../core/import/import_types.dart';
import '../../core/model/piece.dart';
import '../../core/model/score.dart';
import '../../core/model/session.dart';
import '../../data/library_repository.dart';
import '../calibration/calibration_screen.dart';
import '../calibration/input_test_screen.dart';
import '../import/import_flow.dart';
import '../practice/practice_launcher.dart';
import '../progress/history_screen.dart';
import '../review/review_screen.dart';
import '../settings/settings_screen.dart';
import '../theme.dart';
import '../widgets/common.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});
  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  String _search = '';
  LibrarySort _sort = LibrarySort.recent;
  bool _favoritesOnly = false;
  List<PracticeSession> _allSessions = [];

  @override
  void initState() {
    super.initState();
    _loadSessions();
  }

  Future<void> _loadSessions() async {
    final s = await context.read<AppState>().library.allSessions();
    if (mounted) setState(() => _allSessions = s);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final pieces = app.library.query(search: _search, sort: _sort, favoritesOnly: _favoritesOnly);
    final empty = app.pieces.isEmpty;
    return Scaffold(
      appBar: AppBar(
        title: const Row(children: [_Logo(), SizedBox(width: 10), Text('Stavelight')]),
        actions: [
          IconButton(
            tooltip: 'Free play',
            icon: const Icon(Icons.piano),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const InputTestScreen())),
          ),
          IconButton(
            tooltip: 'Input & calibration',
            icon: Icon(_inputIcon(app.activeInput)),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const CalibrationScreen())),
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () async {
              await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen()));
              _loadSessions();
            },
          ),
        ],
      ),
      floatingActionButton: empty
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _import(context),
              icon: const Icon(Icons.add),
              label: const Text('Import sheet music'),
            ),
      body: SafeArea(
        child: empty
            ? _EmptyLibrary(onImport: () => _import(context))
            : RefreshIndicator(
                onRefresh: _loadSessions,
                child: CustomScrollView(slivers: [
                  SliverToBoxAdapter(child: _Header(sessions: _allSessions)),
                  SliverToBoxAdapter(child: _controls()),
                  if (pieces.isEmpty)
                    const SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(child: Padding(padding: EdgeInsets.all(32), child: Text('Nothing matches your search.'))),
                    )
                  else
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
                      sliver: SliverGrid(
                        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 420,
                          // Grow the card with the text size so large Dynamic Type doesn't clip it.
                          mainAxisExtent: 132 + 72 * (MediaQuery.textScalerOf(context).scale(16) / 16 - 1).clamp(0.0, 1.5),
                          mainAxisSpacing: 12,
                          crossAxisSpacing: 12,
                        ),
                        delegate: SliverChildBuilderDelegate(
                          (c, i) => _PieceCard(piece: pieces[i], onChanged: _loadSessions),
                          childCount: pieces.length,
                        ),
                      ),
                    ),
                ]),
              ),
      ),
    );
  }

  IconData _inputIcon(InputKind k) => switch (k) {
        InputKind.midi => Icons.cable,
        InputKind.mic => Icons.mic_none,
        InputKind.none => Icons.tune,
      };

  Widget _controls() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(children: [
        SearchBar(
          hintText: 'Search your library',
          leading: const Icon(Icons.search),
          elevation: const WidgetStatePropertyAll(0),
          onChanged: (v) => setState(() => _search = v),
        ),
        const SizedBox(height: 8),
        Row(children: [
          FilterChip(
            label: const Text('Favorites'),
            avatar: Icon(_favoritesOnly ? Icons.star : Icons.star_border, size: 18),
            selected: _favoritesOnly,
            showCheckmark: false,
            onSelected: (v) => setState(() => _favoritesOnly = v),
          ),
          const Spacer(),
          PopupMenuButton<LibrarySort>(
            tooltip: 'Sort',
            initialValue: _sort,
            onSelected: (s) => setState(() => _sort = s),
            itemBuilder: (_) => const [
              PopupMenuItem(value: LibrarySort.recent, child: Text('Recently practiced')),
              PopupMenuItem(value: LibrarySort.title, child: Text('Title')),
              PopupMenuItem(value: LibrarySort.imported, child: Text('Date imported')),
              PopupMenuItem(value: LibrarySort.progress, child: Text('Progress')),
            ],
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(children: [
                const Icon(Icons.sort, size: 20),
                const SizedBox(width: 6),
                Text(switch (_sort) {
                  LibrarySort.recent => 'Recent',
                  LibrarySort.title => 'Title',
                  LibrarySort.imported => 'Imported',
                  LibrarySort.progress => 'Progress',
                }),
              ]),
            ),
          ),
        ]),
      ]),
    );
  }

  Future<void> _import(BuildContext context) async {
    final id = await startImport(context);
    if (id != null && context.mounted) {
      await openReview(context, id);
      _loadSessions();
    }
  }
}

Future<void> openReview(BuildContext context, String pieceId) => Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (c) => ReviewScreen(pieceId: pieceId, onPractice: () => launchPractice(c, pieceId)),
    ));

class _Logo extends StatelessWidget {
  const _Logo();
  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return ExcludeSemantics(
      child: CustomPaint(size: const Size(28, 28), painter: _LogoPainter(c.primary, SlColors.brass)),
    );
  }
}

/// Original mark: five staff lines with a rising light-beam note.
class _LogoPainter extends CustomPainter {
  final Color a, b;
  _LogoPainter(this.a, this.b);
  @override
  void paint(Canvas canvas, Size s) {
    final line = Paint()
      ..color = a
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < 5; i++) {
      final y = s.height * (0.2 + i * 0.15);
      canvas.drawLine(Offset(0, y), Offset(s.width, y), line);
    }
    canvas.drawOval(Rect.fromCenter(center: Offset(s.width * 0.42, s.height * 0.72), width: s.width * 0.36, height: s.height * 0.26), Paint()..color = b);
    canvas.drawLine(Offset(s.width * 0.6, s.height * 0.7), Offset(s.width * 0.6, s.height * 0.05), Paint()
      ..color = b
      ..strokeWidth = 2.4);
  }

  @override
  bool shouldRepaint(_LogoPainter o) => o.a != a || o.b != b;
}

class _EmptyLibrary extends StatelessWidget {
  final VoidCallback onImport;
  const _EmptyLibrary({required this.onImport});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.library_music_outlined, size: 72, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 16),
            Text('Your library is empty', style: t.headlineSmall, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            Text(
              'Stavelight practices the music you bring. Import your own sheet music to start: '
              'a PDF, a photo or scan of a page, a MusicXML file, or a MIDI file.\n\n'
              'Everything stays on this device. No account needed.',
              style: t.bodyLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(onPressed: onImport, icon: const Icon(Icons.file_open_outlined), label: const Text('Import sheet music')),
            const SizedBox(height: 16),
            const _FormatRow(),
          ]),
        ),
      ),
    );
  }
}

class _FormatRow extends StatelessWidget {
  const _FormatRow();
  @override
  Widget build(BuildContext context) {
    Widget item(IconData i, String label, String note) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [Icon(i, size: 20), const SizedBox(width: 10), Expanded(child: Text('$label — $note'))]),
        );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          item(Icons.music_note, 'MIDI, MusicXML', 'most accurate; practice right away'),
          item(Icons.picture_as_pdf_outlined, 'PDF', 'notes are recognized on-device, then you review them'),
          item(Icons.photo_camera_outlined, 'Photos & scans', 'crop and straighten first; expect some corrections'),
        ]),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final List<PracticeSession> sessions;
  const _Header({required this.sessions});
  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>().settings;
    final now = DateTime.now();
    final today = AppState.minutesOn(sessions, now);
    final parts = <Widget>[];
    if (s.dailyGoalMinutes > 0) {
      final frac = (today / s.dailyGoalMinutes).clamp(0.0, 1.0);
      parts.add(Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Today: $today of ${s.dailyGoalMinutes} min', style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 6),
          LinearProgressIndicator(value: frac, minHeight: 6, borderRadius: BorderRadius.circular(3)),
        ]),
      ));
    }
    if (s.streaksOptIn) {
      final streak = AppState.streakFrom(sessions, now);
      if (parts.isNotEmpty) parts.add(const SizedBox(width: 16));
      parts.add(Row(children: [
        const Icon(Icons.local_fire_department_outlined, size: 20),
        const SizedBox(width: 4),
        Text(streak == 0 ? 'Start a streak today' : '$streak-day streak'),
      ]));
    }
    if (parts.isEmpty) return const SizedBox(height: 4);
    return Padding(padding: const EdgeInsets.fromLTRB(20, 8, 20, 0), child: Row(children: parts));
  }
}

class _PieceCard extends StatelessWidget {
  final Piece piece;
  final VoidCallback onChanged;
  const _PieceCard({required this.piece, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final c = Theme.of(context).colorScheme;
    final pct = (piece.progress * 100).round();
    return Semantics(
      button: true,
      label: '${piece.title}${piece.composer != null ? ' by ${piece.composer}' : ''}, $pct percent progress'
          '${piece.needsReview ? ', needs review' : ''}',
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => launchPractice(context, piece.id),
          onLongPress: () => _menu(context),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              _Thumb(piece: piece),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
                  Row(children: [
                    if (piece.favorite) const Padding(padding: EdgeInsets.only(right: 4), child: Icon(Icons.star, size: 18, color: SlColors.brass)),
                    Expanded(child: Text(piece.title, style: t.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis)),
                  ]),
                  if (piece.composer != null) Text(piece.composer!, style: t.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 4),
                  Text('${_formatLabel(piece.format)} · ${formatDate(piece.importedAt)}', style: t.bodySmall?.copyWith(color: c.onSurfaceVariant), maxLines: 1, overflow: TextOverflow.ellipsis),
                  const Spacer(),
                  Row(children: [
                    Expanded(child: LinearProgressIndicator(value: piece.progress, minHeight: 6, borderRadius: BorderRadius.circular(3))),
                    const SizedBox(width: 8),
                    Text('$pct%', style: t.labelMedium),
                  ]),
                  if (piece.needsReview)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Row(children: [
                        const Icon(Icons.help_outline, size: 14, color: SlColors.warn),
                        const SizedBox(width: 4),
                        Text('Needs review', style: t.labelSmall?.copyWith(color: SlColors.warn)),
                      ]),
                    ),
                ]),
              ),
              IconButton(tooltip: 'More actions', icon: const Icon(Icons.more_vert), onPressed: () => _menu(context)),
            ]),
          ),
        ),
      ),
    );
  }

  static String _formatLabel(ImportFormat f) => switch (f) {
        ImportFormat.midi => 'MIDI',
        ImportFormat.musicxml || ImportFormat.mxl => 'MusicXML',
        ImportFormat.pdf => 'PDF',
        ImportFormat.image => 'Image',
        ImportFormat.unknown => 'File',
      };

  Future<void> _menu(BuildContext context) async {
    final app = context.read<AppState>();
    final repo = app.library;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(title: Text(piece.title, style: Theme.of(c).textTheme.titleMedium)),
            ListTile(leading: const Icon(Icons.play_arrow), title: const Text('Practice'), onTap: () => Navigator.pop(c, 'practice')),
            ListTile(leading: const Icon(Icons.edit_note), title: const Text('Review & edit score'), onTap: () => Navigator.pop(c, 'review')),
            ListTile(leading: const Icon(Icons.insights_outlined), title: const Text('Progress history'), onTap: () => Navigator.pop(c, 'history')),
            ListTile(
                leading: Icon(piece.favorite ? Icons.star : Icons.star_border),
                title: Text(piece.favorite ? 'Remove from favorites' : 'Add to favorites'),
                onTap: () => Navigator.pop(c, 'fav')),
            ListTile(leading: const Icon(Icons.drive_file_rename_outline), title: const Text('Rename'), onTap: () => Navigator.pop(c, 'rename')),
            ListTile(leading: const Icon(Icons.copy_outlined), title: const Text('Duplicate'), onTap: () => Navigator.pop(c, 'dup')),
            ListTile(
                leading: const Icon(Icons.refresh),
                title: const Text('Re-import / replace file'),
                subtitle: const Text('Keeps practice history'),
                onTap: () => Navigator.pop(c, 'replace')),
            if (piece.format == ImportFormat.pdf || piece.format == ImportFormat.image)
              ListTile(
                  leading: const Icon(Icons.document_scanner_outlined),
                  title: const Text('Reprocess original'),
                  subtitle: const Text('Run recognition again with new settings'),
                  onTap: () => Navigator.pop(c, 'reprocess')),
            ListTile(
                leading: Icon(Icons.delete_outline, color: Theme.of(c).colorScheme.error),
                title: Text('Delete', style: TextStyle(color: Theme.of(c).colorScheme.error)),
                onTap: () => Navigator.pop(c, 'delete')),
          ]),
        ),
      ),
    );
    if (!context.mounted || action == null) return;
    switch (action) {
      case 'practice':
        await launchPractice(context, piece.id);
      case 'review':
        await openReview(context, piece.id);
      case 'history':
        await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => HistoryScreen(pieceId: piece.id)));
      case 'fav':
        await repo.setFavorite(piece.id, !piece.favorite);
      case 'rename':
        await _rename(context);
      case 'dup':
        await repo.duplicate(piece.id);
      case 'replace':
        final id = await startImport(context, replacePieceId: piece.id);
        if (id != null && context.mounted) await openReview(context, id);
      case 'reprocess':
        final id = await reprocessPiece(context, piece.id);
        if (id != null && context.mounted) await openReview(context, id);
      case 'delete':
        final ok = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: Text('Delete “${piece.title}”?'),
            content: const Text('The imported file, the edited score and its practice history will be removed from this device. This cannot be undone.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
              FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: Theme.of(c).colorScheme.error),
                  onPressed: () => Navigator.pop(c, true),
                  child: const Text('Delete')),
            ],
          ),
        );
        if (ok == true) await repo.delete(piece.id);
    }
    app.libraryChanged();
    onChanged();
  }

  Future<void> _rename(BuildContext context) async {
    final title = TextEditingController(text: piece.title);
    final composer = TextEditingController(text: piece.composer ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Rename'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: title, decoration: const InputDecoration(labelText: 'Title'), autofocus: true),
          const SizedBox(height: 8),
          TextField(controller: composer, decoration: const InputDecoration(labelText: 'Composer (optional)')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      await context.read<AppState>().library.rename(piece.id, title.text, composer: composer.text);
    }
  }
}

/// Thumbnail: first page image for scans, otherwise a mini piano-roll of the score.
class _Thumb extends StatefulWidget {
  final Piece piece;
  const _Thumb({required this.piece});
  @override
  State<_Thumb> createState() => _ThumbState();
}

class _ThumbState extends State<_Thumb> {
  File? _page;
  Score? _score;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_Thumb old) {
    super.didUpdateWidget(old);
    if (old.piece.updatedAt != widget.piece.updatedAt) _load();
  }

  Future<void> _load() async {
    final repo = context.read<AppState>().library;
    final pages = await repo.pageImages(widget.piece.id);
    final score = pages.isEmpty ? await repo.loadScore(widget.piece.id) : null;
    if (mounted) {
      setState(() {
        _page = pages.isEmpty ? null : pages.first;
        _score = score;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return ExcludeSemantics(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: 84,
          height: 108,
          color: c.surfaceContainerHighest,
          child: _page != null
              ? Image.file(_page!, fit: BoxFit.cover, alignment: Alignment.topCenter, cacheWidth: 200)
              : CustomPaint(painter: _RollPainter(_score, Theme.of(context).brightness)),
        ),
      ),
    );
  }
}

class _RollPainter extends CustomPainter {
  final Score? score;
  final Brightness b;
  _RollPainter(this.score, this.b);
  @override
  void paint(Canvas canvas, Size size) {
    final s = score;
    if (s == null || s.notes.isEmpty) return;
    final notes = s.notes.take(160).toList();
    final end = notes.map((n) => n.startTick + n.durationTicks).reduce((a, b) => a > b ? a : b).toDouble();
    var lo = notes.map((n) => n.midi).reduce((a, b) => a < b ? a : b);
    var hi = notes.map((n) => n.midi).reduce((a, b) => a > b ? a : b);
    if (hi - lo < 12) hi = lo + 12;
    for (final n in notes) {
      final x = 6 + (n.midi - lo) / (hi - lo) * (size.width - 16);
      final y0 = size.height - 6 - n.startTick / end * (size.height - 12);
      final h = (n.durationTicks / end * (size.height - 12)).clamp(2.0, size.height);
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(x, y0 - h, 4, h), const Radius.circular(2)),
        Paint()..color = SlColors.hand(n.hand, b).withValues(alpha: 0.85),
      );
    }
  }

  @override
  bool shouldRepaint(_RollPainter o) => o.score != score;
}
