import 'dart:convert';

/// Which sync backend the app should use.
enum BackendKind { stub, googleDrive, webdav, folder }

/// Snapshot of sync configuration. Stored as JSON in secure storage.
class BackendConfig {
  const BackendConfig({
    required this.kind,
    this.webdavUrl,
    this.webdavUser,
    this.webdavPassword,
    this.folderPath,
  });

  final BackendKind kind;
  final String? webdavUrl;
  final String? webdavUser;
  final String? webdavPassword;

  /// Absolute filesystem path of the vault directory for [BackendKind.folder].
  /// External tools (Syncthing, Dropbox, iCloud Drive) keep that folder in
  /// sync between devices.
  final String? folderPath;

  static const stub = BackendConfig(kind: BackendKind.stub);

  String toJsonString() => jsonEncode(<String, dynamic>{
        'kind': kind.name,
        if (webdavUrl != null) 'webdavUrl': webdavUrl,
        if (webdavUser != null) 'webdavUser': webdavUser,
        if (webdavPassword != null) 'webdavPassword': webdavPassword,
        if (folderPath != null) 'folderPath': folderPath,
      });

  static BackendConfig fromJsonString(String? raw) {
    if (raw == null || raw.isEmpty) return stub;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return BackendConfig(
        kind: BackendKind.values.firstWhere(
          (k) => k.name == j['kind'],
          orElse: () => BackendKind.stub,
        ),
        webdavUrl: j['webdavUrl'] as String?,
        webdavUser: j['webdavUser'] as String?,
        webdavPassword: j['webdavPassword'] as String?,
        folderPath: j['folderPath'] as String?,
      );
    } catch (_) {
      return stub;
    }
  }

  String get label => switch (kind) {
        BackendKind.stub => 'Local only (no cloud)',
        BackendKind.googleDrive => 'Google Drive',
        BackendKind.webdav => 'WebDAV',
        BackendKind.folder => 'Local folder${folderPath == null ? '' : ' ($folderPath)'}',
      };
}
