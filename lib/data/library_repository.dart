import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as ppath;

import '../core/import/import_types.dart';
import '../core/model/calibration.dart';
import '../core/model/piece.dart';
import '../core/model/score.dart';
import '../core/model/session.dart';
import '../core/util/ids.dart';
import 'json_store.dart';

enum LibrarySort { recent, title, imported, progress }

/// Owns everything stored on the device: originals, derived scores, sessions, calibration.
/// Layout under [root]:
///   library.json, calibration.json
///   pieces/ID/original_N.EXT, score.json, pages/page_N.png
///   sessions/PIECE_ID.json (or _free.json)
class LibraryRepository {
  final Directory root;
  final List<Piece> _pieces = [];
  bool _loaded = false;

  LibraryRepository(this.root);

  List<Piece> get pieces => List.unmodifiable(_pieces);
  File get _indexFile => File(ppath.join(root.path, 'library.json'));
  File get _calibrationFile => File(ppath.join(root.path, 'calibration.json'));
  Directory pieceDir(String id) => Directory(ppath.join(root.path, 'pieces', id));
  File _scoreFile(String id) => File(ppath.join(pieceDir(id).path, 'score.json'));
  File _sessionsFile(String? pieceId) => File(ppath.join(root.path, 'sessions', '${pieceId ?? '_free'}.json'));

  Future<void> load() async {
    if (_loaded) return;
    await root.create(recursive: true);
    final data = await JsonStore.read(_indexFile);
    _pieces
      ..clear()
      ..addAll(((data as List?) ?? const []).map((e) => Piece.fromJson((e as Map).cast<String, dynamic>())));
    // Drop entries whose folder disappeared (e.g. user cleared storage partially).
    _pieces.removeWhere((p) => !pieceDir(p.id).existsSync());
    _loaded = true;
  }

  Future<void> _saveIndex() => JsonStore.write(_indexFile, _pieces.map((p) => p.toJson()).toList());

  Piece? byId(String id) {
    for (final p in _pieces) {
      if (p.id == id) return p;
    }
    return null;
  }

  List<Piece> query({String search = '', LibrarySort sort = LibrarySort.recent, bool favoritesOnly = false}) {
    final q = search.trim().toLowerCase();
    final list = _pieces.where((p) {
      if (favoritesOnly && !p.favorite) return false;
      if (q.isEmpty) return true;
      return p.title.toLowerCase().contains(q) || (p.composer ?? '').toLowerCase().contains(q);
    }).toList();
    int byRecent(Piece a, Piece b) =>
        (b.lastPracticedAt ?? b.updatedAt).compareTo(a.lastPracticedAt ?? a.updatedAt);
    list.sort(switch (sort) {
      LibrarySort.recent => byRecent,
      LibrarySort.title => (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
      LibrarySort.imported => (a, b) => b.importedAt.compareTo(a.importedAt),
      LibrarySort.progress => (a, b) => b.progress.compareTo(a.progress),
    });
    // Favorites float to the top within any sort.
    list.sort((a, b) => (b.favorite ? 1 : 0) - (a.favorite ? 1 : 0));
    return list;
  }

  static String _ext(String name, ImportFormat f) {
    final dot = name.lastIndexOf('.');
    if (dot > 0 && name.length - dot <= 9) return name.substring(dot + 1).toLowerCase();
    return switch (f) {
      ImportFormat.midi => 'mid',
      ImportFormat.musicxml => 'musicxml',
      ImportFormat.mxl => 'mxl',
      ImportFormat.pdf => 'pdf',
      ImportFormat.image => 'jpg',
      ImportFormat.unknown => 'bin',
    };
  }

  /// Store a new piece: original file(s) are copied verbatim so they can be reprocessed later.
  Future<Piece> addPiece({
    required List<(String name, Uint8List bytes)> originals,
    required ImportFormat format,
    required Score score,
    List<Uint8List> processedPages = const [],
  }) async {
    final id = newId('pc');
    final dir = pieceDir(id);
    await dir.create(recursive: true);
    final names = await _writeOriginals(dir, originals, format);
    await _writePages(id, processedPages);
    final now = DateTime.now();
    final piece = Piece(
      id: id,
      title: score.title,
      composer: score.composer,
      importedAt: now,
      updatedAt: now,
      format: format,
      originals: names,
      sourceName: originals.map((o) => o.$1).join(', '),
      needsReview: score.review == ReviewState.recognized || score.uncertainCount > 0,
    );
    await JsonStore.write(_scoreFile(id), score.toJson());
    _pieces.add(piece);
    await _saveIndex();
    return piece;
  }

  Future<List<String>> _writeOriginals(Directory dir, List<(String, Uint8List)> originals, ImportFormat f) async {
    final names = <String>[];
    for (var i = 0; i < originals.length; i++) {
      final name = 'original_$i.${_ext(originals[i].$1, f)}';
      await File(ppath.join(dir.path, name)).writeAsBytes(originals[i].$2, flush: true);
      names.add(name);
    }
    return names;
  }

  Future<void> _writePages(String id, List<Uint8List> pages) async {
    final dir = Directory(ppath.join(pieceDir(id).path, 'pages'));
    if (await dir.exists()) await dir.delete(recursive: true);
    if (pages.isEmpty) return;
    await dir.create(recursive: true);
    for (var i = 0; i < pages.length; i++) {
      await File(ppath.join(dir.path, 'page_$i.png')).writeAsBytes(pages[i], flush: true);
    }
  }

  Future<List<File>> pageImages(String id) async {
    final dir = Directory(ppath.join(pieceDir(id).path, 'pages'));
    if (!await dir.exists()) return [];
    final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.png')).toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    return files;
  }

  Future<List<(String, Uint8List)>> readOriginals(String id) async {
    final piece = byId(id);
    if (piece == null) return [];
    return [
      for (final n in piece.originals) (n, await File(ppath.join(pieceDir(id).path, n)).readAsBytes()),
    ];
  }

  /// Replace the original and derived score (re-import). Practice history is kept.
  Future<void> replace(String id, {
    required List<(String, Uint8List)> originals,
    required ImportFormat format,
    required Score score,
    List<Uint8List> processedPages = const [],
  }) async {
    final piece = byId(id);
    if (piece == null) return;
    final dir = pieceDir(id);
    for (final n in piece.originals) {
      final f = File(ppath.join(dir.path, n));
      if (await f.exists()) await f.delete();
    }
    piece.originals = await _writeOriginals(dir, originals, format);
    piece.format = format;
    piece.sourceName = originals.map((o) => o.$1).join(', ');
    piece.updatedAt = DateTime.now();
    piece.needsReview = score.review == ReviewState.recognized || score.uncertainCount > 0;
    piece.resumeMeasure = 0;
    await _writePages(id, processedPages);
    await JsonStore.write(_scoreFile(id), score.toJson());
    await _saveIndex();
  }

  Future<Score?> loadScore(String id) async {
    final j = await JsonStore.read(_scoreFile(id));
    return j == null ? null : Score.fromJson((j as Map).cast<String, dynamic>());
  }

  /// Autosave target for the review editor.
  Future<void> saveScore(String id, Score score) async {
    await JsonStore.write(_scoreFile(id), score.toJson());
    final p = byId(id);
    if (p != null) {
      p.title = score.title;
      p.composer = score.composer;
      p.updatedAt = DateTime.now();
      p.needsReview = score.review != ReviewState.verified && score.uncertainCount > 0;
      await _saveIndex();
    }
  }

  Future<void> update(Piece piece) async {
    piece.updatedAt = DateTime.now();
    await _saveIndex();
  }

  Future<void> rename(String id, String title, {String? composer}) async {
    final p = byId(id);
    if (p == null) return;
    p.title = title.trim().isEmpty ? p.title : title.trim();
    p.composer = composer?.trim().isEmpty ?? true ? null : composer!.trim();
    final s = await loadScore(id);
    if (s != null) {
      s.title = p.title;
      s.composer = p.composer;
      await JsonStore.write(_scoreFile(id), s.toJson());
    }
    await update(p);
  }

  Future<void> setFavorite(String id, bool fav) async {
    final p = byId(id);
    if (p == null) return;
    p.favorite = fav;
    await _saveIndex();
  }

  Future<Piece?> duplicate(String id) async {
    final p = byId(id);
    if (p == null) return null;
    final newPid = newId('pc');
    await _copyDir(pieceDir(id), pieceDir(newPid));
    final now = DateTime.now();
    final copy = Piece.fromJson({
      ...p.toJson(),
      'id': newPid,
      'title': '${p.title} (copy)',
      'importedAt': now.toIso8601String(),
      'updatedAt': now.toIso8601String(),
      'favorite': false,
      'progress': 0.0,
      'sessions': 0,
      'practiceSeconds': 0,
      'resumeMeasure': 0,
    })..lastPracticedAt = null;
    final s = await loadScore(newPid);
    if (s != null) {
      s.title = copy.title;
      await JsonStore.write(_scoreFile(newPid), s.toJson());
    }
    _pieces.add(copy);
    await _saveIndex();
    return copy;
  }

  Future<void> _copyDir(Directory from, Directory to) async {
    await to.create(recursive: true);
    await for (final e in from.list(recursive: false)) {
      final name = ppath.basename(e.path);
      if (e is File) {
        await e.copy(ppath.join(to.path, name));
      } else if (e is Directory) {
        await _copyDir(e, Directory(ppath.join(to.path, name)));
      }
    }
  }

  Future<void> delete(String id) async {
    _pieces.removeWhere((p) => p.id == id);
    final dir = pieceDir(id);
    if (await dir.exists()) await dir.delete(recursive: true);
    final sessions = _sessionsFile(id);
    if (await sessions.exists()) await sessions.delete();
    await _saveIndex();
  }

  // ---- Sessions & progress ---------------------------------------------------------------------

  Future<List<PracticeSession>> sessions(String? pieceId) async {
    final j = await JsonStore.read(_sessionsFile(pieceId));
    return ((j as List?) ?? const [])
        .map((e) => PracticeSession.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
  }

  Future<List<PracticeSession>> allSessions() async {
    final dir = Directory(ppath.join(root.path, 'sessions'));
    if (!await dir.exists()) return [];
    final out = <PracticeSession>[];
    for (final f in dir.listSync().whereType<File>().where((f) => f.path.endsWith('.json'))) {
      final j = await JsonStore.read(f);
      out.addAll(((j as List?) ?? const []).map((e) => PracticeSession.fromJson((e as Map).cast<String, dynamic>())));
    }
    out.sort((a, b) => a.startedAt.compareTo(b.startedAt));
    return out;
  }

  /// Store a session and update the piece's progress. Low-quality sessions don't move progress.
  Future<void> recordSession(PracticeSession s, {int? measureCount, int? resumeMeasure}) async {
    final list = await sessions(s.pieceId)..add(s);
    await JsonStore.write(_sessionsFile(s.pieceId), list.map((e) => e.toJson()).toList());
    final piece = s.pieceId == null ? null : byId(s.pieceId!);
    if (piece == null) return;
    piece.sessions++;
    piece.practiceSeconds += s.durationSec;
    piece.lastPracticedAt = s.startedAt;
    if (resumeMeasure != null) piece.resumeMeasure = resumeMeasure;
    if (measureCount != null && measureCount > 0) piece.progress = progressFrom(list, measureCount);
    await _saveIndex();
  }

  /// Mean over measures of the best accuracy reached in any reliable session.
  static double progressFrom(List<PracticeSession> sessions, int measureCount) {
    final best = <int, double>{};
    for (final s in sessions) {
      if (s.lowQuality) continue;
      s.perMeasure.forEach((m, st) {
        final a = st.accuracy;
        if (a != null && st.expected >= 1 && a > (best[m] ?? 0)) best[m] = a;
      });
    }
    if (best.isEmpty) return 0;
    final sum = best.values.fold<double>(0, (a, b) => a + b);
    return (sum / measureCount).clamp(0, 1).toDouble();
  }

  // ---- Calibration -----------------------------------------------------------------------------

  Future<Map<String, CalibrationProfile>> loadCalibrations() async {
    final j = await JsonStore.read(_calibrationFile);
    final m = <String, CalibrationProfile>{};
    for (final e in ((j as List?) ?? const [])) {
      final p = CalibrationProfile.fromJson((e as Map).cast<String, dynamic>());
      m[p.key] = p;
    }
    return m;
  }

  Future<void> saveCalibration(CalibrationProfile p) async {
    final all = await loadCalibrations();
    all[p.key] = p;
    await JsonStore.write(_calibrationFile, all.values.map((e) => e.toJson()).toList());
  }

  // ---- Backup & deletion -----------------------------------------------------------------------

  /// Zip of everything the user owns (originals, scores, sessions, calibration, settings).
  Future<Uint8List> exportBackup() async {
    final archive = Archive();
    final files = root.listSync(recursive: true).whereType<File>().where((f) => !f.path.endsWith('.tmp'));
    for (final f in files) {
      // Zip entries use forward slashes by convention, regardless of host OS.
      final rel = ppath.relative(f.path, from: root.path).replaceAll(r'\', '/');
      final bytes = await f.readAsBytes();
      archive.addFile(ArchiveFile(rel, bytes.length, bytes));
    }
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }

  Future<void> deleteAll() async {
    _pieces.clear();
    if (await root.exists()) await root.delete(recursive: true);
    await root.create(recursive: true);
  }
}
