import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart' as xml;

import 'sync_backend.dart';

/// Stores one encrypted JSON envelope per note inside a single folder on a
/// WebDAV server. Tested against Nextcloud; should work with any RFC-4918
/// implementation that supports PROPFIND, GET, PUT and DELETE.
///
/// The base URL must point at the directory that holds the notes, e.g.
///   https://cloud.example.com/remote.php/dav/files/alice/StickyNotes
class WebDavBackend implements SyncBackend {
  WebDavBackend._(this._client, this._base, this._authHeader);

  final http.Client _client;
  final Uri _base;
  final String _authHeader;

  static Future<WebDavBackend> connect({
    required String url,
    required String username,
    required String password,
  }) async {
    final base = _ensureTrailingSlash(Uri.parse(url));
    final auth =
        'Basic ${base64Encode(utf8.encode('$username:$password'))}';
    final client = http.Client();
    final backend = WebDavBackend._(client, base, auth);
    await backend._ensureFolderExists();
    return backend;
  }

  /// Lightweight credential check: HEAD the folder.
  static Future<({bool ok, String? error})> testConnection({
    required String url,
    required String username,
    required String password,
  }) async {
    try {
      final base = _ensureTrailingSlash(Uri.parse(url));
      final auth =
          'Basic ${base64Encode(utf8.encode('$username:$password'))}';
      final res = await http.Client().send(http.Request('PROPFIND', base)
        ..headers['Authorization'] = auth
        ..headers['Depth'] = '0');
      if (res.statusCode == 207 ||
          res.statusCode == 200 ||
          res.statusCode == 404) {
        // 404 → we'll try to create it on connect().
        return (ok: true, error: null);
      }
      return (ok: false, error: 'HTTP ${res.statusCode}');
    } catch (e) {
      return (ok: false, error: e.toString());
    }
  }

  static Uri _ensureTrailingSlash(Uri u) =>
      u.path.endsWith('/') ? u : u.replace(path: '${u.path}/');

  Future<void> _ensureFolderExists() async {
    final res = await _send('PROPFIND', _base, headers: {'Depth': '0'});
    if (res.statusCode == 404) {
      // MKCOL to create.
      final mk = await _send('MKCOL', _base);
      if (mk.statusCode >= 300 && mk.statusCode != 405) {
        throw Exception('MKCOL failed: ${mk.statusCode}');
      }
    }
  }

  Future<http.StreamedResponse> _send(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    List<int>? body,
  }) async {
    final req = http.Request(method, uri)
      ..headers['Authorization'] = _authHeader;
    headers.forEach((k, v) => req.headers.putIfAbsent(k, () => v));
    if (body != null) req.bodyBytes = body;
    return _client.send(req);
  }

  Uri _fileFor(String id) => _base.resolve('${Uri.encodeComponent(id)}.json');

  // --- SyncBackend ---------------------------------------------------------

  @override
  Future<Map<String, String>> pullManifest() async {
    final res = await _send('PROPFIND', _base, headers: {'Depth': '1'});
    if (res.statusCode != 207) {
      throw Exception('PROPFIND failed: ${res.statusCode}');
    }
    final body = await res.stream.bytesToString();
    final doc = xml.XmlDocument.parse(body);

    final out = <String, String>{};
    for (final resp in doc.findAllElements('response',
        namespaceUri: 'DAV:')) {
      final href = resp.findElements('href', namespaceUri: 'DAV:').firstOrNull;
      if (href == null) continue;
      final path = Uri.decodeFull(href.innerText);
      final name = path.split('/').where((s) => s.isNotEmpty).lastOrNull ?? '';
      if (!name.endsWith('.json')) continue;
      final id = name.substring(0, name.length - 5);

      // Prefer getetag; fall back to getlastmodified.
      String? tag;
      for (final propstat in resp.findElements('propstat', namespaceUri: 'DAV:')) {
        final prop = propstat.findElements('prop', namespaceUri: 'DAV:').firstOrNull;
        if (prop == null) continue;
        final etag = prop.findElements('getetag', namespaceUri: 'DAV:').firstOrNull;
        if (etag != null && etag.innerText.isNotEmpty) {
          tag = etag.innerText;
          break;
        }
        final mtime =
            prop.findElements('getlastmodified', namespaceUri: 'DAV:').firstOrNull;
        if (mtime != null && mtime.innerText.isNotEmpty) {
          tag = mtime.innerText;
        }
      }
      out[id] = tag ?? '';
    }
    return out;
  }

  @override
  Future<Map<String, dynamic>?> pullOne(String id) async {
    try {
      final r = await _send('GET', _fileFor(id));
      if (r.statusCode == 404) return null;
      if (r.statusCode != 200) {
        throw Exception('GET failed: ${r.statusCode}');
      }
      final body = await r.stream.bytesToString();
      return jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<Map<String, Map<String, dynamic>>> pullAll() async {
    final manifest = await pullManifest();
    final out = <String, Map<String, dynamic>>{};
    for (final id in manifest.keys) {
      final env = await pullOne(id);
      if (env != null) out[id] = env;
    }
    return out;
  }

  @override
  Future<void> push(String id, Map<String, dynamic> envelope) async {
    final res = await _send('PUT', _fileFor(id),
        headers: {'Content-Type': 'application/json'},
        body: utf8.encode(jsonEncode(envelope)));
    if (res.statusCode >= 300) {
      throw Exception('PUT failed: ${res.statusCode}');
    }
  }

  @override
  Future<void> delete(String id) async {
    final res = await _send('DELETE', _fileFor(id));
    if (res.statusCode >= 300 && res.statusCode != 404) {
      throw Exception('DELETE failed: ${res.statusCode}');
    }
  }
}
