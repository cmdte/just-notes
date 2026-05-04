import 'dart:convert';
import 'dart:io';

import 'sync_backend.dart';

/// Filesystem-backed sync. Each note is one JSON file at `<dir>/<id>.json`.
/// External tooling (Syncthing, Dropbox, iCloud Drive, …) is expected to
/// keep [dir] in sync between devices.
class FolderBackend implements SyncBackend {
  FolderBackend._(this._dir);

  final Directory _dir;

  static Future<FolderBackend> connect(String path) async {
    final dir = Directory(path);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return FolderBackend._(dir);
  }

  /// Verifies the path is writable. Returns null on success or an error
  /// message suitable for displaying in the UI.
  static Future<String?> probe(String path) async {
    try {
      final dir = Directory(path);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final probe = File('${dir.path}/.just_notes_probe');
      await probe.writeAsString('ok', flush: true);
      await probe.delete();
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  File _fileFor(String id) => File('${_dir.path}/$id.json');

  static String _tagFor(FileStat stat) =>
      '${stat.modified.microsecondsSinceEpoch}-${stat.size}';

  @override
  Future<Map<String, String>> pullManifest() async {
    final out = <String, String>{};
    if (!await _dir.exists()) return out;
    await for (final entity in _dir.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (!name.endsWith('.json')) continue;
      final id = name.substring(0, name.length - 5);
      try {
        out[id] = _tagFor(await entity.stat());
      } catch (_) {/* skip */}
    }
    return out;
  }

  @override
  Future<Map<String, dynamic>?> pullOne(String id) async {
    final f = _fileFor(id);
    if (!await f.exists()) return null;
    try {
      final raw = await f.readAsString();
      if (raw.trim().isEmpty) return null;
      return (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<Map<String, Map<String, dynamic>>> pullAll() async {
    final out = <String, Map<String, dynamic>>{};
    if (!await _dir.exists()) return out;
    await for (final entity in _dir.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (!name.endsWith('.json')) continue;
      final id = name.substring(0, name.length - 5);
      try {
        final raw = await entity.readAsString();
        if (raw.trim().isEmpty) continue;
        out[id] = (jsonDecode(raw) as Map).cast<String, dynamic>();
      } catch (_) {/* skip corrupt */}
    }
    return out;
  }

  @override
  Future<void> push(String id, Map<String, dynamic> envelope) async {
    final f = _fileFor(id);
    await f.writeAsString(jsonEncode(envelope), flush: true);
  }

  @override
  Future<void> delete(String id) async {
    final f = _fileFor(id);
    if (await f.exists()) await f.delete();
  }
}
