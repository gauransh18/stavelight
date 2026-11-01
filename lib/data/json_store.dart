import 'dart:convert';
import 'dart:io';

/// Atomic JSON file helpers: write to a temp file, then rename over the target.
class JsonStore {
  static Future<void> write(File f, Object json) async {
    await f.parent.create(recursive: true);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(json), flush: true);
    await tmp.rename(f.path);
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
