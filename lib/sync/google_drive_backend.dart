import 'dart:convert';

import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;

import 'sync_backend.dart';

/// Syncs encrypted note envelopes to the user's own Google Drive, inside
/// the hidden per-app `appDataFolder` (invisible to the user, auto-deleted
/// when they uninstall the app, never counted toward visible Drive storage).
///
/// Setup the user has to do once (outside this code):
///   1. Create a Google Cloud project, enable the Google Drive API.
///   2. Create an "Android" OAuth 2.0 Client ID using the app's package
///      name (`com.example.just_notes` by default) and the SHA-1 of the
///      keystore that signs the APK they install.
///   3. Add an OAuth consent screen, scope `drive.appdata`.
/// No client ID is hardcoded here — `GoogleSignIn` discovers it via the
/// platform OAuth client registered in Google Cloud.
class GoogleDriveBackend implements SyncBackend {
  GoogleDriveBackend._(this._driveApi);

  final drive.DriveApi _driveApi;

  static const _scopes = <String>[drive.DriveApi.driveAppdataScope];

  /// Web OAuth client ID from Google Cloud (Application type: "Web
  /// application"). Required by `google_sign_in` 7.x on Android even though
  /// the Android OAuth client (matched by package name + SHA-1) is what
  /// actually authorizes the device.
  static const _serverClientId =
      '322530812683-ipnmncvupdqh0f7arl4pj03oah4dvhlv.apps.googleusercontent.com';

  static bool _initialized = false;

  static Future<void> _ensureInit() async {
    if (_initialized) return;
    await GoogleSignIn.instance.initialize(serverClientId: _serverClientId);
    _initialized = true;
  }

  /// Sign in (interactive if needed) and return a connected backend.
  /// Returns null if the user cancels or sign-in fails.
  static Future<GoogleDriveBackend?> connect() async {
    await _ensureInit();
    final signIn = GoogleSignIn.instance;

    GoogleSignInAccount? account =
        await signIn.attemptLightweightAuthentication();
    if (account == null) {
      try {
        account = await signIn.authenticate();
      } on GoogleSignInException {
        return null;
      }
    }

    final authClient = account.authorizationClient;
    GoogleSignInClientAuthorization? authorization =
        await authClient.authorizationForScopes(_scopes);
    authorization ??= await authClient.authorizeScopes(_scopes);

    final client = authorization.authClient(scopes: _scopes);
    return GoogleDriveBackend._(drive.DriveApi(client));
  }

  static Future<void> signOut() async {
    await _ensureInit();
    await GoogleSignIn.instance.signOut();
  }

  static Future<String?> currentEmail() async {
    await _ensureInit();
    final account =
        await GoogleSignIn.instance.attemptLightweightAuthentication();
    return account?.email;
  }

  // --- index ---------------------------------------------------------------

  /// One file per note id, stored in the appDataFolder.
  /// File name is `<id>.json`, contents are the JSON envelope.
  Future<Map<String, drive.File>> _listIndex() async {
    final result = <String, drive.File>{};
    String? pageToken;
    do {
      final res = await _driveApi.files.list(
        spaces: 'appDataFolder',
        q: "trashed = false and mimeType = 'application/json'",
        $fields: 'nextPageToken, files(id,name,modifiedTime)',
        pageToken: pageToken,
        pageSize: 1000,
      );
      for (final f in res.files ?? const <drive.File>[]) {
        final name = f.name ?? '';
        if (!name.endsWith('.json')) continue;
        result[name.substring(0, name.length - 5)] = f;
      }
      pageToken = res.nextPageToken;
    } while (pageToken != null);
    return result;
  }

  Future<Map<String, dynamic>> _download(drive.File f) async {
    final media = await _driveApi.files.get(
      f.id!,
      downloadOptions: drive.DownloadOptions.fullMedia,
    ) as drive.Media;
    final bytes = <int>[];
    await for (final chunk in media.stream) {
      bytes.addAll(chunk);
    }
    return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  }

  // --- SyncBackend ---------------------------------------------------------

  @override
  Future<Map<String, String>> pullManifest() async {
    final index = await _listIndex();
    return index.map((id, f) => MapEntry(
          id,
          f.modifiedTime?.toUtc().toIso8601String() ?? '',
        ));
  }

  @override
  Future<Map<String, dynamic>?> pullOne(String id) async {
    final index = await _listIndex();
    final f = index[id];
    if (f == null) return null;
    try {
      return await _download(f);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<Map<String, Map<String, dynamic>>> pullAll() async {
    final index = await _listIndex();
    final out = <String, Map<String, dynamic>>{};
    for (final entry in index.entries) {
      try {
        out[entry.key] = await _download(entry.value);
      } catch (_) {/* skip */}
    }
    return out;
  }

  @override
  Future<void> push(String id, Map<String, dynamic> envelope) async {
    final body = utf8.encode(jsonEncode(envelope));
    final media = drive.Media(Stream.value(body), body.length);

    final index = await _listIndex();
    final existing = index[id];
    if (existing == null) {
      final meta = drive.File()
        ..name = '$id.json'
        ..mimeType = 'application/json'
        ..parents = ['appDataFolder'];
      await _driveApi.files.create(meta, uploadMedia: media);
    } else {
      // Update needs an empty File metadata.
      await _driveApi.files.update(drive.File(), existing.id!,
          uploadMedia: media);
    }
  }

  @override
  Future<void> delete(String id) async {
    final index = await _listIndex();
    final existing = index[id];
    if (existing != null) {
      await _driveApi.files.delete(existing.id!);
    }
  }
}
