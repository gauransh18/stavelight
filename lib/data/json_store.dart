import 'dart:convert';
import 'dart:io';

/// Atomic JSON file helpers: write to a temp file, then rename over the target.
class JsonStore {
  static Future<void> write(File f, Object json) async {
    await f.parent.create(recursive: true);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(json), flush: true);
    try {
      await tmp.rename(f.path);
    } on FileSystemException {
      // Windows (Win32 MoveFile) cannot rename over an existing file, unlike
      // POSIX rename. Fall back to replace-then-rename. This keeps the write
      // close to atomic: data is fully flushed to tmp before the swap, and a
      // crash in the tiny window leaves tmp recoverable.
      if (await f.exists()) await f.delete();
      await tmp.rename(f.path);
    }
  }

  static Future<dynamic> read(File f) async {
    if (!await f.exists()) return null;
    try {
      return jsonDecode(await f.readAsString());
    } on FormatException {
      // Corrupt file (e.g. power loss before rename on an old version). Keep a copy for diagnostics.
      await f.copy('${f.path}.corrupt');
      return null;
    }
  }
}
