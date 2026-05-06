import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'backend_config.dart';
import 'folder_backend.dart';
import 'google_drive_backend.dart';
import 'webdav_backend.dart';

/// Abstraction over a remote (or stub) sync backend.
///
/// All payloads handled here are already encrypted envelopes — the backend
/// never sees plaintext. Swap implementations freely.
///
/// Implementations expose a manifest-driven API so the repository can do
/// delta syncs (pull only what changed) instead of redownloading every
/// envelope on every cycle.
abstract class SyncBackend {
  /// List every id present remotely along with an opaque version tag
  /// (ETag, modifiedTime, content hash, …). Two calls returning the same
  /// tag for the same id mean the payload is unchanged.
  Future<Map<String, String>> pullManifest();

  /// Fetch a single envelope by id, or null if it no longer exists.
  Future<Map<String, dynamic>?> pullOne(String id);

  /// Pull every encrypted envelope. Default implementation walks the
  /// manifest. Backends may override for one-shot bulk download.
  Future<Map<String, Map<String, dynamic>>> pullAll() async {
    final manifest = await pullManifest();
    final out = <String, Map<String, dynamic>>{};
    for (final id in manifest.keys) {
      final env = await pullOne(id);
      if (env != null) out[id] = env;
    }
    return out;
  }

  /// Push (insert or overwrite) a single encrypted note.
  Future<void> push(String id, Map<String, dynamic> envelope);

  /// Remove a note by id.
  Future<void> delete(String id);
}

/// Builds a backend from a saved [BackendConfig]. Returns `null` if the
/// configured backend can't be instantiated (e.g. the user has not signed
/// in to Drive yet, or WebDAV creds are missing) — callers should fall
/// back to the local stub.
Future<SyncBackend?> buildBackend(BackendConfig cfg, {bool silent = false}) async {
  switch (cfg.kind) {
    case BackendKind.stub:
      return LocalStubBackend.create();
    case BackendKind.googleDrive:
      return GoogleDriveBackend.connect(silent: silent);
    case BackendKind.webdav:
      if (cfg.webdavUrl == null ||
          cfg.webdavUser == null ||
          cfg.webdavPassword == null) {
        return null;
      }
      return WebDavBackend.connect(
        url: cfg.webdavUrl!,
        username: cfg.webdavUser!,
        password: cfg.webdavPassword!,
      );
    case BackendKind.folder:
      if (cfg.folderPath == null || cfg.folderPath!.isEmpty) return null;
      return FolderBackend.connect(cfg.folderPath!);
  }
}


/// File-backed stub that mimics a cloud bucket on disk.
/// Useful for testing or retaining a purely local backend.
class LocalStubBackend implements SyncBackend {
  LocalStubBackend._(this._file);

  final File _file;

  static Future<LocalStubBackend> create() async {
    final dir = await getApplicationSupportDirectory();
    final file = File('${dir.path}/cloud_stub.json');
    if (!await file.exists()) {
      await file.writeAsString('{}');
    }
    return LocalStubBackend._(file);
  }

  Future<Map<String, dynamic>> _read() async {
    final raw = await _file.readAsString();
    if (raw.isEmpty) return <String, dynamic>{};
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  Future<void> _write(Map<String, dynamic> data) =>
      _file.writeAsString(jsonEncode(data), flush: true);

  @override
  Future<Map<String, String>> pullManifest() async {
    final raw = await _read();
    return raw.map(
      (k, v) => MapEntry(k, _tagFor((v as Map).cast<String, dynamic>())),
    );
  }

  @override
  Future<Map<String, dynamic>?> pullOne(String id) async {
    final raw = await _read();
    final v = raw[id];
    if (v == null) return null;
    return (v as Map).cast<String, dynamic>();
  }

  @override
  Future<Map<String, Map<String, dynamic>>> pullAll() async {
    final raw = await _read();
    return raw.map((k, v) => MapEntry(k, (v as Map).cast<String, dynamic>()));
  }

  @override
  Future<void> push(String id, Map<String, dynamic> envelope) async {
    final data = await _read();
    data[id] = envelope;
    await _write(data);
  }

  @override
  Future<void> delete(String id) async {
    final data = await _read();
    data.remove(id);
    await _write(data);
  }

  /// Cheap content-derived tag. Composed from the ciphertext length and
  /// the per-write random nonce, both of which change on every push, so
  /// the tag changes iff the envelope changes.
  static String _tagFor(Map<String, dynamic> envelope) {
    final ct = envelope['ct'] as String? ?? '';
    final nonce = envelope['nonce'] as String? ?? '';
    return '${ct.length}-$nonce';
  }
}
