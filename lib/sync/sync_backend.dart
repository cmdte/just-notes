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
abstract class SyncBackend {
  /// Pull every encrypted note envelope, keyed by note id.
  Future<Map<String, Map<String, dynamic>>> pullAll();

  /// Push (insert or overwrite) a single encrypted note.
  Future<void> push(String id, Map<String, dynamic> envelope);

  /// Remove a note by id.
  Future<void> delete(String id);
}

/// Builds a backend from a saved [BackendConfig]. Returns `null` if the
/// configured backend can't be instantiated (e.g. the user has not signed
/// in to Drive yet, or WebDAV creds are missing) — callers should fall
/// back to the local stub.
Future<SyncBackend?> buildBackend(BackendConfig cfg) async {
  switch (cfg.kind) {
    case BackendKind.stub:
      return LocalStubBackend.create();
    case BackendKind.googleDrive:
      return GoogleDriveBackend.connect();
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
/// Replace with a real client (Firestore, Supabase, S3, ...) when ready.
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
}
