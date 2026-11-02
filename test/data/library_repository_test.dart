import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stavelight/core/import/import_types.dart';
import 'package:stavelight/core/model/pitch.dart';
import 'package:stavelight/core/model/score.dart';
import 'package:stavelight/core/model/session.dart';
import 'package:stavelight/data/library_repository.dart';
import 'package:stavelight/data/settings_repository.dart';

Score score(String title) => Score(
      title: title,
      origin: ScoreOrigin.midi,
      notes: [ScoreNote(id: 'n1', midi: 60, startTick: 0, durationTicks: 480)],
      measures: [Measure(index: 0, startTick: 0, lengthTicks: 1920, number: '1', time: const TimeSignature(4, 4), key: const KeySignature(0))],
    );

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('sl_lib'));
  tearDown(() async => dir.delete(recursive: true));

  test('imported piece survives an app restart (new repository instance)', () async {
    final repo = LibraryRepository(dir);
    await repo.load();
    final original = Uint8List.fromList([0x4D, 0x54, 0x68, 0x64, 1, 2, 3]);
    final p = await repo.addPiece(originals: [('My Song.mid', original)], format: ImportFormat.midi, score: score('My Song'));

    final reopened = LibraryRepository(dir);
    await reopened.load();
    expect(reopened.pieces.map((e) => e.title), ['My Song']);
    final s = await reopened.loadScore(p.id);
    expect(s!.notes.single.midi, 60);
    final orig = await reopened.readOriginals(p.id);
    expect(orig.single.$2, original); // original preserved byte-for-byte for reprocessing
  });

  test('rename, favorite, duplicate, search/sort, delete', () async {
    final repo = LibraryRepository(dir);
    await repo.load();
    final a = await repo.addPiece(originals: [('a.mid', Uint8List(4))], format: ImportFormat.midi, score: score('Alpha'));
    final b = await repo.addPiece(originals: [('b.mid', Uint8List(4))], format: ImportFormat.midi, score: score('Beta'));
    await repo.rename(a.id, 'Zulu', composer: 'Someone');
    await repo.setFavorite(b.id, true);
    final copy = await repo.duplicate(a.id);
    expect(copy!.title, 'Zulu (copy)');
    expect((await repo.loadScore(copy.id))!.title, 'Zulu (copy)');
    expect(repo.query(sort: LibrarySort.title).first.title, 'Beta'); // favorite first
    expect(repo.query(search: 'someone').length, 2);
    await repo.delete(a.id);
    expect(repo.pieces.length, 2);
    expect(Directory('${dir.path}/pieces/${a.id}').existsSync(), isFalse);
  });

  test('sessions update progress; low-quality sessions are ignored', () async {
    final repo = LibraryRepository(dir);
    await repo.load();
    final p = await repo.addPiece(originals: [('a.mid', Uint8List(4))], format: ImportFormat.midi, score: score('A'));
    final s1 = PracticeSession(id: 's1', pieceId: p.id, startedAt: DateTime.now(), durationSec: 60)
      ..perMeasure = {0: MeasureStat()..expected = 4..correct = 3, 1: MeasureStat()..expected = 4..correct = 4};
    await repo.recordSession(s1, measureCount: 2, resumeMeasure: 1);
    expect(repo.byId(p.id)!.progress, closeTo(0.875, 1e-9));
    final noisy = PracticeSession(id: 's2', pieceId: p.id, startedAt: DateTime.now())
      ..lowQuality = true
      ..perMeasure = {0: MeasureStat()..expected = 4..correct = 4};
    await repo.recordSession(noisy, measureCount: 2);
    expect(repo.byId(p.id)!.progress, closeTo(0.875, 1e-9));
    expect((await repo.sessions(p.id)).length, 2);
    expect(repo.byId(p.id)!.resumeMeasure, 1);
  });

  test('backup zip and delete all', () async {
    final repo = LibraryRepository(dir);
    await repo.load();
    await repo.addPiece(originals: [('a.mid', Uint8List(4))], format: ImportFormat.midi, score: score('A'));
    await SettingsRepository(dir).save(AppSettings()..noteNames = false);
    final zip = await repo.exportBackup();
    expect(zip.sublist(0, 2), [0x50, 0x4B]);
    expect((await SettingsRepository(dir).load()).noteNames, isFalse);
    await repo.deleteAll();
    expect(repo.pieces, isEmpty);
    expect(dir.listSync(), isEmpty);
  });

  test('backup zip entries use forward slashes on every platform', () async {
    final repo = LibraryRepository(dir);
    await repo.load();
    // A piece stores originals under pieces/<id>/..., i.e. nested paths that on
    // Windows would otherwise use backslashes.
    await repo.addPiece(originals: [('a.mid', Uint8List(4))], format: ImportFormat.midi, score: score('A'));
    final zip = await repo.exportBackup();
    final archive = ZipDecoder().decodeBytes(zip);
    expect(archive.files, isNotEmpty);
    for (final f in archive.files) {
      expect(f.name.contains('\\'), isFalse, reason: 'zip entry must not contain backslashes: ${f.name}');
    }
    // At least one entry is nested (proving we exercised a multi-segment path).
    expect(archive.files.any((f) => f.name.contains('/')), isTrue);
  });
}
