import 'dart:convert';

import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:googleapis_auth/googleapis_auth.dart' as gapis;
import 'package:http/http.dart' as http;

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

  drive.DriveApi _driveApi;

  static const _scopes = <String>[drive.DriveApi.driveAppdataScope];
  static const _storage = FlutterSecureStorage();
  static const _tokenKey = 'google_drive_access_token';

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

  /// Build a DriveApi client from a raw access token string.
  static GoogleDriveBackend _fromToken(String token) {
    final creds = gapis.AccessCredentials(
      gapis.AccessToken(
        'Bearer',
        token,
        DateTime.now().toUtc().add(const Duration(days: 365)),
      ),
      null,
      _scopes,
    );
    final client = gapis.authenticatedClient(http.Client(), creds);
    return GoogleDriveBackend._(drive.DriveApi(client));
  }

  /// Try to restore a backend from a cached access token (no UI).
  /// Returns null if no cached token or the token is invalid.
  static Future<GoogleDriveBackend?> _tryFromCache() async {
    final token = await _storage.read(key: _tokenKey);
    if (token == null) return null;
    final backend = _fromToken(token);
    try {
      // Quick probe to verify the token is still valid.
      await backend._driveApi.files.list(
        spaces: 'appDataFolder',
        pageSize: 1,
        $fields: 'files(id)',
      );
      return backend;
    } catch (_) {
      await _storage.delete(key: _tokenKey);
      return null;
    }
  }

  /// Sign in (interactive if needed) and return a connected backend.
  /// Returns null if the user cancels or sign-in fails.
  ///
  /// When [silent] is true, tries the cached token first, then lightweight
  /// auth. Returns null instead of showing a login popup.
  ///
  /// When [interactive] is true, skips the cached token and lightweight
  /// auth, going straight to the full account picker.
  static Future<GoogleDriveBackend?> connect({
    bool silent = false,
    bool interactive = false,
  }) async {
    // 1. Try cached token — no Google Sign-In SDK involved.
    if (!interactive) {
      final cached = await _tryFromCache();
      if (cached != null) return cached;
    }

    // 2. Fall through to Google Sign-In.
    await _ensureInit();
    final signIn = GoogleSignIn.instance;

    GoogleSignInAccount? account;
    if (!interactive) {
      account = await signIn.attemptLightweightAuthentication();
    }
    if (account == null) {
      if (silent) return null;
      try {
        account = await signIn.authenticate();
      } on GoogleSignInException {
        return null;
      }
    }

    final authClient = account.authorizationClient;
    GoogleSignInClientAuthorization? authorization =
        await authClient.authorizationForScopes(_scopes);
    if (authorization == null) {
      if (silent) return null;
      authorization = await authClient.authorizeScopes(_scopes);
    }

    // Cache the token for future launches.
    final token = authorization.accessToken;
    await _storage.write(key: _tokenKey, value: token);

    final client = authorization.authClient(scopes: _scopes);
    return GoogleDriveBackend._(drive.DriveApi(client));
  }

  static Future<void> signOut() async {
    await _storage.delete(key: _tokenKey);
    await _ensureInit();
    await GoogleSignIn.instance.signOut();
  }

  /// Re-authenticate via Google Sign-In and update the cached token.
  /// Called when the cached token turns out to be expired mid-session.
  Future<bool> _refreshToken() async {
    await _ensureInit();
    final signIn = GoogleSignIn.instance;

    final account = await signIn.attemptLightweightAuthentication();
    if (account == null) return false;

    final authClient = account.authorizationClient;
    final authorization = await authClient.authorizationForScopes(_scopes);
    if (authorization == null) return false;

    final token = authorization.accessToken;
    await _storage.write(key: _tokenKey, value: token);
    final client = authorization.authClient(scopes: _scopes);
    _driveApi = drive.DriveApi(client);
    return true;
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
    try {
      return await _pullManifestInner();
    } on drive.DetailedApiRequestError catch (e) {
      if (e.status == 401 && await _refreshToken()) {
        return _pullManifestInner();
      }
      rethrow;
    }
  }

  Future<Map<String, String>> _pullManifestInner() async {
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
