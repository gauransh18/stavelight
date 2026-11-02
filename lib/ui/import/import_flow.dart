import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../../app/app_state.dart';
import '../../core/import/import_types.dart';
import '../../core/import/midi_parser.dart';
import '../../core/import/musicxml_parser.dart';
import '../../core/import/track_selection.dart';
import '../../core/model/score.dart';
import '../../core/platform/platform_capabilities.dart';
import '../../services/pdf_raster.dart';
import 'omr_run_screen.dart';
import 'page_editor_screen.dart';
import 'isolate_jobs.dart';
import 'track_select_screen.dart';

enum _Source { file, camera, photos }

/// Entry point for importing. Returns the new (or replaced) piece id, or null if cancelled/failed.
Future<String?> startImport(BuildContext context, {String? replacePieceId}) async {
  final source = await showModalBottomSheet<_Source>(
    context: context,
    showDragHandle: true,
    builder: (c) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(
          title: Text(replacePieceId == null ? 'Import sheet music' : 'Replace with a new file', style: Theme.of(c).textTheme.titleMedium),
          subtitle: const Text('PDF, image, MusicXML (.musicxml, .xml, .mxl) or MIDI (.mid)'),
        ),
        ListTile(leading: const Icon(Icons.folder_open), title: const Text('Choose a file'), onTap: () => Navigator.pop(c, _Source.file)),
        if (PlatformCaps.cameraCapture)
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: const Text('Photograph pages'),
            subtitle: const Text('Uses the camera; you can add several pages'),
            onTap: () => Navigator.pop(c, _Source.camera),
          ),
        if (PlatformCaps.photoLibrary)
          ListTile(leading: const Icon(Icons.photo_library_outlined), title: const Text('Choose photos'), onTap: () => Navigator.pop(c, _Source.photos)),
        const SizedBox(height: 8),
      ]),
    ),
  );
  if (source == null || !context.mounted) return null;

  List<(String, Uint8List)> files;
  try {
    if (source == _Source.camera) {
      files = await _capturePages(context);
    } else {
      files = source == _Source.file ? await _pickFiles() : await _pickPhotos();
    }
  } on PlatformException catch (e) {
    if (context.mounted) await _permissionOrError(context, e);
    return null;
  }
  if (files.isEmpty || !context.mounted) return null;
  return importFiles(context, files, replacePieceId: replacePieceId);
}

Future<List<(String, Uint8List)>> _pickFiles() async {
  // FileType.any: extension filters grey out .mid/.mxl in some Android pickers. Content is sniffed instead.
  final picked = await FilePicker.pickFiles(type: FileType.any);
  return [for (final f in picked) (f.name, await f.readAsBytes())];
}

Future<List<(String, Uint8List)>> _pickPhotos() async {
  final picked = await ImagePicker().pickMultiImage(imageQuality: 95);
  return [for (final x in picked) (x.name, await x.readAsBytes())];
}

Future<List<(String, Uint8List)>> _capturePages(BuildContext context) async {
  final out = <(String, Uint8List)>[];
  final picker = ImagePicker();
  while (true) {
    final x = await picker.pickImage(source: ImageSource.camera, imageQuality: 95);
    if (x == null) break;
    out.add(('page_${out.length + 1}.jpg', await x.readAsBytes()));
    if (!context.mounted) break;
    final more = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Page ${out.length} captured'),
        content: const Text('Tip: hold the phone parallel to the page, in good light, with the whole page in view.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Done')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Add another page')),
        ],
      ),
    );
    if (more != true) break;
  }
  return out;
}

Future<void> _permissionOrError(BuildContext context, PlatformException e) async {
  final denied = e.code.contains('access_denied') || e.code.contains('permission');
  await showDialog<void>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(denied ? 'Camera or photo access is off' : 'Could not open the picker'),
      content: Text(denied
          ? 'Stavelight only uses the camera when you photograph pages. You can allow access in Settings, or import a PDF or image file instead.'
          : 'Something went wrong (${e.message ?? e.code}). You can try again or choose a file instead.'),
      actions: [
        if (denied && PlatformCaps.appSettingsLink)
          TextButton(
            onPressed: () async {
              try {
                await openAppSettings();
              } catch (_) {
                /* no-op on platforms without an app-settings deep link */
              }
            },
            child: const Text('Open settings'),
          ),
        FilledButton(onPressed: () => Navigator.pop(c), child: const Text('OK')),
      ],
    ),
  );
}

String _titleFrom(String fileName) {
  final base = fileName.split('/').last;
  final dot = base.lastIndexOf('.');
  final t = (dot > 0 ? base.substring(0, dot) : base).replaceAll(RegExp(r'[_]+'), ' ').trim();
  return t.isEmpty ? 'Untitled' : t;
}

/// Runs [work] behind a modal progress indicator.
Future<T> withProgress<T>(BuildContext context, String message, Future<T> Function() work) async {
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (c) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(children: [const CircularProgressIndicator(), const SizedBox(width: 20), Expanded(child: Text(message))]),
      ),
    ),
  );
  try {
    return await work();
  } finally {
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
  }
}

Future<void> showImportError(BuildContext context, String title, String message) => showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        icon: const Icon(Icons.error_outline),
        title: Text(title),
        content: Text(message),
        actions: [FilledButton(onPressed: () => Navigator.pop(c), child: const Text('OK'))],
      ),
    );

/// Import already-read files. Digital formats are parsed; PDFs/images go through page editing and OMR.
Future<String?> importFiles(BuildContext context, List<(String, Uint8List)> files, {String? replacePieceId}) async {
  final formats = [for (final f in files) sniffFormat(f.$2, fileName: f.$1)];
  if (formats.contains(ImportFormat.unknown)) {
    final bad = files[formats.indexOf(ImportFormat.unknown)].$1;
    await showImportError(context, 'Unsupported file',
        '“$bad” isn’t a format Stavelight can read. Supported: PDF, JPG/PNG images, MusicXML (.musicxml, .xml, .mxl) and MIDI (.mid).');
    return null;
  }
  final digital = formats.where((f) => f == ImportFormat.midi || f == ImportFormat.musicxml || f == ImportFormat.mxl).length;
  if (digital > 0 && files.length > 1) {
    await showImportError(context, 'One file at a time', 'Import MIDI or MusicXML files one at a time. Several images or a PDF can be combined into one piece.');
    return null;
  }
  try {
    if (digital == 1) return await _importDigital(context, files.single, formats.single, replacePieceId);
    return await _importScan(context, files, formats, replacePieceId);
  } on ImportException catch (e) {
    if (context.mounted) await showImportError(context, 'Couldn’t import', e.message);
    return null;
  }
}

Future<String?> _importDigital(BuildContext context, (String, Uint8List) file, ImportFormat format, String? replaceId) async {
  final title = _titleFrom(file.$1);
  Score score;
  try {
    score = switch (format) {
      ImportFormat.midi => parseMidi(file.$2, title: title),
      ImportFormat.mxl => parseMxl(file.$2, fallbackTitle: title),
      _ => parseMusicXml(utf8.decode(file.$2, allowMalformed: true).replaceFirst('\uFEFF', ''), fallbackTitle: title),
    };
  } on ImportException {
    rethrow;
  } catch (e) {
    throw ImportException('This file could not be read. It may be damaged or use features Stavelight doesn’t support yet.', '$e');
  }

  final needsChoice = score.tracks.length > 1 || score.notes.any((n) => n.hand == Hand.unassigned);
  if (needsChoice) {
    if (!context.mounted) return null;
    final result = await Navigator.of(context).push<(List<TrackInfo>, int)>(
      MaterialPageRoute(builder: (_) => TrackSelectScreen(score: score)),
    );
    if (result == null) return null;
    score = applyTrackSelection(score, result.$1, split: result.$2);
  }
  if (!context.mounted) return null;
  final app = context.read<AppState>();
  final repo = app.library;
  String id;
  if (replaceId != null) {
    await repo.replace(replaceId, originals: [file], format: format, score: score);
    id = replaceId;
  } else {
    id = (await repo.addPiece(originals: [file], format: format, score: score)).id;
  }
  app.libraryChanged();
  return id;
}

Future<List<img.Image>> _decodeAll(List<(String, Uint8List)> files, List<ImportFormat> formats) async {
  final pages = <img.Image>[];
  for (var i = 0; i < files.length; i++) {
    if (formats[i] == ImportFormat.pdf) {
      pages.addAll(await PdfRaster.render(files[i].$2));
    } else {
      final decoded = await decodeImageBytes(files[i].$2);
      if (decoded == null) {
        throw ImportException('“${files[i].$1}” couldn’t be decoded. HEIC photos may need to be exported as JPEG first.');
      }
      pages.add(decoded);
    }
  }
  return pages;
}

Future<String?> _importScan(BuildContext context, List<(String, Uint8List)> files, List<ImportFormat> formats, String? replaceId) async {
  final pages = await withProgress(context, 'Preparing pages…', () => _decodeAll(files, formats));
  if (!context.mounted) return null;
  return _scanPipeline(context, pages, originals: files, format: formats.contains(ImportFormat.pdf) ? ImportFormat.pdf : ImportFormat.image,
      title: _titleFrom(files.first.$1), replaceId: replaceId);
}

Future<String?> _scanPipeline(
  BuildContext context,
  List<img.Image> pages, {
  required List<(String, Uint8List)> originals,
  required ImportFormat format,
  required String title,
  String? replaceId,
}) async {
  var working = pages;
  while (true) {
    if (!context.mounted) return null;
    final edited = await Navigator.of(context).push<List<img.Image>>(
      MaterialPageRoute(builder: (_) => PageEditorScreen(pages: working)),
    );
    if (edited == null || edited.isEmpty || !context.mounted) return null;
    working = edited;
    final outcome = await Navigator.of(context).push<OmrOutcome>(
      MaterialPageRoute(builder: (_) => OmrRunScreen(pages: working, title: title)),
    );
    if (outcome == null || !context.mounted) return null;
    if (outcome.editPages) continue;
    final score = outcome.score!;
    final pngs = await withProgress(context, 'Saving…', () => encodePagePngs(working));
    if (!context.mounted) return null;
    final app = context.read<AppState>();
    String id;
    if (replaceId != null) {
      await app.library.replace(replaceId, originals: originals, format: format, score: score, processedPages: pngs);
      id = replaceId;
    } else {
      id = (await app.library.addPiece(originals: originals, format: format, score: score, processedPages: pngs)).id;
    }
    app.libraryChanged();
    return id;
  }
}

/// Re-run page editing and recognition from the stored original file(s).
Future<String?> reprocessPiece(BuildContext context, String pieceId) async {
  final repo = context.read<AppState>().library;
  final piece = repo.byId(pieceId);
  if (piece == null) return null;
  final originals = await repo.readOriginals(pieceId);
  if (originals.isEmpty || !context.mounted) return null;
  final formats = [for (final o in originals) sniffFormat(o.$2, fileName: o.$1)];
  try {
    final pages = await withProgress(context, 'Preparing pages…', () => _decodeAll(originals, formats));
    if (!context.mounted) return null;
    return _scanPipeline(context, pages, originals: originals, format: piece.format, title: piece.title, replaceId: pieceId);
  } on ImportException catch (e) {
    if (context.mounted) await showImportError(context, 'Couldn’t reprocess', e.message);
    return null;
  }
}

/// An empty score for manual entry when recognition can't be trusted.
Score emptyScore(String title, OmrSettings s, {int measures = 8}) {
  final len = s.time.measureTicks(kPpq);
  return Score(
    title: title,
    origin: ScoreOrigin.manual,
    review: ReviewState.recognized,
    tempos: [TempoEvent(0, s.bpm)],
    measures: [
      for (var i = 0; i < measures; i++)
        Measure(index: i, startTick: i * len, lengthTicks: len, number: '${i + 1}', time: s.time, key: s.key),
    ],
    issues: [ScoreIssue('Enter notes manually: select a measure and tap Add note.', severity: 'info')],
  );
}
