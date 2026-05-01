import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../crypto/note_crypto.dart';
import '../models/note.dart';
import '../sync/backend_config.dart';
import '../sync/google_drive_backend.dart';
import '../sync/sync_backend.dart';

/// Single source of truth for the UI.
/// Owns the in-memory note list, the local cache file, the crypto key,
/// and the sync backend.
class NotesRepository extends ChangeNotifier {
  NotesRepository._(
    this._crypto,
    this._backend,
    this._cacheFile,
    this._tombstonesFile,
    this._cfg,
  );

  static const _saltStorageKey = 'vault_salt_b64';
  static const _verifierStorageKey = 'vault_verifier';
  static const _rememberedPassKey = 'vault_pass_remembered';
  static const _backendCfgKey = 'backend_config_json';
  static const _lastSyncKey = 'vault_last_sync_iso';
  static const _verifierPlaintext = 'sticky-notes-vault-ok';
  static const _vaultDescriptorId = '__vault__';
  static const _tombstonesDocId = '__tombstones__';

  /// Tombstones older than this are pruned from the synced blob to keep it
  /// from growing unboundedly. 7 days covers any reasonable offline window
  /// for a single user with a few devices.
  static const _tombstoneTtl = Duration(days: 7);

  /// Debounce window for auto-sync after a local change.
  static const _autoSyncDelay = Duration(milliseconds: 800);

  static const _storage = FlutterSecureStorage();

  NoteCrypto _crypto;
  SyncBackend _backend;
  BackendConfig _cfg;
  final File _cacheFile;
  final File _tombstonesFile;
  final _uuid = const Uuid();

  final Map<String, Note> _notes = <String, Note>{};
  final Map<String, DateTime> _tombstones = <String, DateTime>{};
  Timer? _autoSyncTimer;
  Timer? _cacheWriteTimer;
  Future<void>? _cacheWriteInFlight;
  bool _syncing = false;
  DateTime? _lastSync;
  String? _lastSyncError;

  // Cached sorted view of [_notes]. Recomputed lazily after mutations
  // instead of on every getter call so the UI's frequent rebuilds stay
  // O(1) and large vaults stay scrollable on budget devices.
  List<Note>? _sortedCache;

  BackendConfig get backendConfig => _cfg;
  DateTime? get lastSync => _lastSync;
  String? get lastSyncError => _lastSyncError;

  List<Note> get notes {
    final cached = _sortedCache;
    if (cached != null) return cached;
    final list = _notes.values.toList()..sort(_orderCmp);
    _sortedCache = List.unmodifiable(list);
    return _sortedCache!;
  }

  @override
  void notifyListeners() {
    // Any change observable to the UI may also have changed membership or
    // ordering, so invalidate the sorted view here in one place rather
    // than sprinkling invalidations at every mutation site.
    _sortedCache = null;
    super.notifyListeners();
  }

  static int _orderCmp(Note a, Note b) {
    final c = a.order.compareTo(b.order);
    if (c != 0) return c;
    // Tie-break: most recently updated first.
    return b.updatedAt.compareTo(a.updatedAt);
  }

  bool get syncing => _syncing;

  // --- bootstrap ----------------------------------------------------------

  /// True if a passphrase has been saved on this device for auto-unlock.
  static Future<bool> hasRememberedPassphrase() async =>
      (await _storage.read(key: _rememberedPassKey)) != null;

  /// True if the vault has been initialized at least once on this device.
  static Future<bool> isInitialized() async =>
      (await _storage.read(key: _saltStorageKey)) != null;

  /// Try to auto-unlock using a passphrase saved on this device.
  /// Returns null if no remembered passphrase exists.
  static Future<({NotesRepository? repo, String? error})?>
      tryAutoUnlock() async {
    final pass = await _storage.read(key: _rememberedPassKey);
    if (pass == null) return null;
    return unlock(pass, remember: true);
  }

  /// Forget any remembered passphrase. Notes stay encrypted on disk.
  static Future<void> forgetPassphrase() =>
      _storage.delete(key: _rememberedPassKey);

  /// Unlock (or create) the vault with a passphrase.
  /// If [remember] is true, the passphrase is stored in the platform secure
  /// store so the next launch auto-unlocks.
  static Future<({NotesRepository? repo, String? error})> unlock(
    String passphrase, {
    bool remember = false,
  }) async {
    final cfgRaw = await _storage.read(key: _backendCfgKey);
    final cfg = BackendConfig.fromJsonString(cfgRaw);

    // Try to connect to the configured backend up-front so we can adopt a
    // vault descriptor (salt + verifier) that was published by another
    // device. If the backend is unavailable (offline, sign-in cancelled),
    // we fall back to the local stub and use the device-local salt.
    SyncBackend? backend;
    Map<String, dynamic>? cloudVault;
    Map<String, Map<String, dynamic>>? remoteSnapshot;
    if (cfg.kind != BackendKind.stub) {
      backend = await buildBackend(cfg);
      if (backend != null) {
        try {
          remoteSnapshot = await backend.pullAll();
          cloudVault = remoteSnapshot.remove(_vaultDescriptorId);
        } catch (_) {/* offline tolerated */}
      }
    }

    String? salt;
    Map<String, dynamic>? verifier;
    if (cloudVault != null) {
      salt = cloudVault['salt'] as String?;
      final v = cloudVault['verifier'];
      if (v is Map) verifier = v.cast<String, dynamic>();
    } else {
      salt = await _storage.read(key: _saltStorageKey);
      final vRaw = await _storage.read(key: _verifierStorageKey);
      if (vRaw != null) {
        verifier = jsonDecode(vRaw) as Map<String, dynamic>;
      }
    }

    final crypto = await NoteCrypto.derive(
      passphrase: passphrase,
      saltB64: salt,
    );

    if (verifier == null) {
      // First-time setup (this device, no cloud descriptor).
      verifier = await crypto.encryptJson({'check': _verifierPlaintext});
    } else {
      try {
        final clear = await crypto.decryptJson(verifier);
        if (clear['check'] != _verifierPlaintext) {
          return (repo: null, error: 'Incorrect passphrase.');
        }
      } catch (_) {
        return (repo: null, error: 'Incorrect passphrase.');
      }
    }

    // Persist (or refresh) salt + verifier locally so future unlocks are
    // fast even if the backend is offline.
    await _storage.write(key: _saltStorageKey, value: crypto.saltB64);
    await _storage.write(
      key: _verifierStorageKey,
      value: jsonEncode(verifier),
    );

    if (remember) {
      await _storage.write(key: _rememberedPassKey, value: passphrase);
    } else {
      await _storage.delete(key: _rememberedPassKey);
    }

    backend ??= await buildBackend(cfg) ?? await LocalStubBackend.create();

    // Publish the vault descriptor if the cloud doesn't have one yet (so
    // the second device can adopt it on its next unlock).
    if (cfg.kind != BackendKind.stub && cloudVault == null) {
      try {
        await backend.push(_vaultDescriptorId, <String, dynamic>{
          'salt': crypto.saltB64,
          'verifier': verifier,
        });
      } catch (_) {/* offline tolerated */}
    }

    final dir = await getApplicationSupportDirectory();
    final cacheFile = File('${dir.path}/notes_cache.json');
    if (!await cacheFile.exists()) await cacheFile.writeAsString('{}');
    final tombstonesFile = File('${dir.path}/tombstones.json');
    if (!await tombstonesFile.exists()) await tombstonesFile.writeAsString('{}');

    final repo = NotesRepository._(
      crypto,
      backend,
      cacheFile,
      tombstonesFile,
      cfg,
    );
    await repo._loadTombstones();
    await repo._loadFromCache();
    await repo._loadLastSync();
    // If we already pulled the remote snapshot above, apply it now so the
    // user sees other devices' notes immediately on first launch — and so
    // notes deleted on other devices are gone *before* the UI ever sees
    // them (no "ghost" flicker).
    if (remoteSnapshot != null) {
      remoteSnapshot.remove(_vaultDescriptorId);
      remoteSnapshot.remove(_tombstonesDocId);
      // Reuse the same deletion-detection used by sync().
      repo._reconcileDeletionsAgainst(remoteSnapshot);
      await repo._applyRemote(remoteSnapshot);
      await repo._writeCache();
      await repo._writeTombstones();
      // Pretend we just synced so the UI shows a sensible timestamp and
      // the deletion-detection baseline advances.
      repo._lastSync = DateTime.now();
      await _storage.write(
        key: _lastSyncKey,
        value: repo._lastSync!.toIso8601String(),
      );
    }
    // Fire-and-forget a follow-up sync (push anything local-only).
    unawaited(repo.sync());
    return (repo: repo, error: null);
  }

  // --- backend switching --------------------------------------------------

  /// Persist a new backend config and reconnect.
  /// If the new backend already holds a vault descriptor (because another
  /// device pushed it), adopt that descriptor: re-derive the key from the
  /// remembered passphrase + cloud salt and re-encrypt the local cache so
  /// future writes are decryptable on every device.
  Future<({bool ok, String? error})> setBackend(BackendConfig cfg) async {
    await _storage.write(key: _backendCfgKey, value: cfg.toJsonString());
    final newBackend = await buildBackend(cfg);
    if (newBackend == null) {
      _cfg = cfg;
      notifyListeners();
      return (ok: false, error: 'Could not connect to backend.');
    }

    if (cfg.kind != BackendKind.stub) {
      try {
        final remote = await newBackend.pullAll();
        final cloudVault = remote.remove(_vaultDescriptorId);
        if (cloudVault != null) {
          final cloudSalt = cloudVault['salt'] as String?;
          final v = cloudVault['verifier'];
          final cloudVerifier = v is Map ? v.cast<String, dynamic>() : null;
          if (cloudSalt != null &&
              cloudVerifier != null &&
              cloudSalt != _crypto.saltB64) {
            // Cloud uses a different vault. Re-derive with the remembered
            // passphrase, validate, then re-encrypt the local cache so we
            // can read what other devices have written.
            final pass = await _storage.read(key: _rememberedPassKey);
            if (pass == null) {
              return (
                ok: false,
                error: 'Re-enter passphrase to switch vaults.',
              );
            }
            final newCrypto = await NoteCrypto.derive(
              passphrase: pass,
              saltB64: cloudSalt,
            );
            try {
              final clear = await newCrypto.decryptJson(cloudVerifier);
              if (clear['check'] != _verifierPlaintext) {
                return (
                  ok: false,
                  error: 'Cloud vault has a different passphrase.',
                );
              }
            } catch (_) {
              return (
                ok: false,
                error: 'Cloud vault has a different passphrase.',
              );
            }
            _crypto = newCrypto;
            await _storage.write(
              key: _saltStorageKey,
              value: newCrypto.saltB64,
            );
            await _storage.write(
              key: _verifierStorageKey,
              value: jsonEncode(cloudVerifier),
            );
          }
        }
        _backend = newBackend;
        _cfg = cfg;

        // Push the descriptor if the cloud doesn't have one.
        if (cloudVault == null) {
          final localVerifierRaw =
              await _storage.read(key: _verifierStorageKey);
          if (localVerifierRaw != null) {
            try {
              await _backend.push(_vaultDescriptorId, <String, dynamic>{
                'salt': _crypto.saltB64,
                'verifier': jsonDecode(localVerifierRaw),
              });
            } catch (_) {/* offline tolerated */}
          }
        }

        // Apply the remote notes we already pulled, then re-write the
        // cache (now encrypted with whatever key we settled on).
        await _applyRemote(remote);
        await _writeCache();
        // Push anything local-only with the (possibly new) key.
        for (final n in _notes.values) {
          if (!remote.containsKey(n.id)) {
            try {
              await _backend.push(
                n.id,
                await _crypto.encryptJson(n.toPlainJson()),
              );
            } catch (_) {/* offline tolerated */}
          }
        }
      } catch (e) {
        notifyListeners();
        return (ok: false, error: 'Sync failed: $e');
      }
    } else {
      _backend = newBackend;
      _cfg = cfg;
    }

    notifyListeners();
    unawaited(sync());
    return (ok: true, error: null);
  }

  /// Sign out from Google Drive and revert to the local stub.
  Future<void> disconnectGoogleDrive() async {
    await GoogleDriveBackend.signOut();
    await setBackend(BackendConfig.stub);
  }

  // --- passphrase change --------------------------------------------------

  /// Change the vault passphrase. Verifies [oldPass], derives a fresh key
  /// from [newPass] (with a brand-new salt), then re-encrypts every note
  /// and the tombstone blob on the configured backend before publishing
  /// the new vault descriptor. Local secure storage is updated last.
  ///
  /// Returns null on success, or a user-facing error message.
  Future<String?> changePassphrase({
    required String oldPass,
    required String newPass,
  }) async {
    if (newPass.isEmpty) return 'New passphrase cannot be empty.';

    // 1. Verify the old passphrase against the stored verifier.
    final storedVerifierRaw = await _storage.read(key: _verifierStorageKey);
    if (storedVerifierRaw == null) {
      return 'Vault is not initialized.';
    }
    final storedVerifier =
        jsonDecode(storedVerifierRaw) as Map<String, dynamic>;
    final oldCrypto = await NoteCrypto.derive(
      passphrase: oldPass,
      saltB64: _crypto.saltB64,
    );
    try {
      final clear = await oldCrypto.decryptJson(storedVerifier);
      if (clear['check'] != _verifierPlaintext) {
        return 'Current passphrase is incorrect.';
      }
    } catch (_) {
      return 'Current passphrase is incorrect.';
    }

    // 2. Derive a new key with a brand-new salt and build the new verifier.
    final newCrypto = await NoteCrypto.derive(passphrase: newPass);
    final newVerifier =
        await newCrypto.encryptJson({'check': _verifierPlaintext});

    // 3. Re-encrypt and push every note with the new key. We push *before*
    //    swapping the descriptor so other devices that pick up the new
    //    descriptor will find decryptable note blobs already in place.
    if (_cfg.kind != BackendKind.stub) {
      try {
        for (final n in _notes.values) {
          await _backend.push(
            n.id,
            await newCrypto.encryptJson(n.toPlainJson()),
          );
        }
        // Re-encrypt tombstones blob too.
        final tombPayload = <String, String>{
          for (final e in _tombstones.entries)
            e.key: e.value.toIso8601String(),
        };
        await _backend.push(
          _tombstonesDocId,
          await newCrypto.encryptJson({'t': tombPayload}),
        );
        // 4. Publish the new descriptor (atomic swap from the cloud's POV).
        await _backend.push(_vaultDescriptorId, <String, dynamic>{
          'salt': newCrypto.saltB64,
          'verifier': newVerifier,
        });
      } catch (e) {
        return 'Could not push re-encrypted vault: $e';
      }
    }

    // 5. Swap in the new key locally and persist new salt + verifier.
    _crypto = newCrypto;
    await _storage.write(key: _saltStorageKey, value: newCrypto.saltB64);
    await _storage.write(
      key: _verifierStorageKey,
      value: jsonEncode(newVerifier),
    );

    // If a passphrase was remembered for auto-unlock, update it.
    if (await _storage.read(key: _rememberedPassKey) != null) {
      await _storage.write(key: _rememberedPassKey, value: newPass);
    }

    notifyListeners();
    return null;
  }

  // --- persistence --------------------------------------------------------

  Future<void> _loadFromCache() async {
    final raw = await _cacheFile.readAsString();
    if (raw.trim().isEmpty) return;
    final data = jsonDecode(raw) as Map<String, dynamic>;
    for (final entry in data.entries) {
      final note = Note.fromPlainJson(
        entry.key,
        (entry.value as Map).cast<String, dynamic>(),
      );
      // Skip notes that have been deleted (here or on another device).
      final ts = _tombstones[entry.key];
      if (ts != null && !note.updatedAt.isAfter(ts)) continue;
      _notes[entry.key] = note;
    }
    notifyListeners();
  }

  Future<void> _writeCache() async {
    final out = <String, dynamic>{
      for (final n in _notes.values) n.id: n.toPlainJson(),
    };
    await _cacheFile.writeAsString(jsonEncode(out), flush: true);
  }

  Future<void> _loadTombstones() async {
    try {
      final raw = await _tombstonesFile.readAsString();
      if (raw.trim().isEmpty) return;
      final data = jsonDecode(raw) as Map<String, dynamic>;
      for (final e in data.entries) {
        final ts = DateTime.tryParse(e.value as String);
        if (ts != null) _tombstones[e.key] = ts;
      }
    } catch (_) {/* ignore */}
  }

  Future<void> _loadLastSync() async {
    final raw = await _storage.read(key: _lastSyncKey);
    if (raw == null) return;
    _lastSync = DateTime.tryParse(raw);
  }

  Future<void> _writeTombstones() async {
    final out = <String, String>{
      for (final e in _tombstones.entries) e.key: e.value.toIso8601String(),
    };
    await _tombstonesFile.writeAsString(jsonEncode(out), flush: true);
  }

  /// Encrypt and push the merged tombstone map to the cloud so other
  /// devices can apply the deletions on their next sync.
  Future<void> _pushTombstones() async {
    if (_cfg.kind == BackendKind.stub) return;
    try {
      final payload = <String, String>{
        for (final e in _tombstones.entries) e.key: e.value.toIso8601String(),
      };
      final envelope = await _crypto.encryptJson({'t': payload});
      await _backend.push(_tombstonesDocId, envelope);
    } catch (_) {/* offline tolerated */}
  }

  // --- CRUD ---------------------------------------------------------------

  Future<Note> create() async {
    // New notes appear at the top → smallest order value.
    final minOrder = _notes.values.isEmpty
        ? 0.0
        : _notes.values.map((n) => n.order).reduce((a, b) => a < b ? a : b);
    final note = Note(
      id: _uuid.v4(),
      title: '',
      content: '',
      colorValue: stickyPalette.first,
      updatedAt: DateTime.now(),
      order: minOrder - 1,
    );
    _notes[note.id] = note;
    notifyListeners();
    // Don't block the UI on disk + network; run persistence in the
    // background so the editor opens immediately.
    unawaited(_persist(note));
    return note;
  }

  /// Move [fromId] to the slot currently held by [toId]. No-op if either is
  /// missing or both are the same id.
  Future<void> reorder(String fromId, String toId) async {
    if (fromId == toId) return;
    final from = _notes[fromId];
    final to = _notes[toId];
    if (from == null || to == null) return;

    final ordered = notes.toList();
    ordered.removeWhere((n) => n.id == fromId);
    final targetIdx = ordered.indexWhere((n) => n.id == toId);
    if (targetIdx < 0) return;
    ordered.insert(targetIdx, from);

    // Reassign dense, integer order values so future inserts stay simple.
    for (var i = 0; i < ordered.length; i++) {
      ordered[i].order = i.toDouble();
    }
    notifyListeners();
    _scheduleCacheWrite();
    // Push every changed note (cheap for typical sticky-note counts).
    for (final n in ordered) {
      try {
        await _backend.push(n.id, await _crypto.encryptJson(n.toPlainJson()));
      } catch (_) {/* offline tolerated */}
    }
    _scheduleAutoSync();
  }

  Future<void> update(Note note) async {
    note.updatedAt = DateTime.now();
    _notes[note.id] = note;
    notifyListeners();
    // Don't block the UI on disk + network.
    unawaited(_persist(note));
  }

  Future<void> delete(String id) async {
    _notes.remove(id);
    _tombstones[id] = DateTime.now();
    notifyListeners();
    _scheduleCacheWrite();
    unawaited(_writeTombstones());
    unawaited(() async {
      try {
        await _backend.delete(id);
      } catch (_) {/* offline tolerated */}
      await _pushTombstones();
    }());
    _scheduleAutoSync();
  }

  Future<void> _persist(Note note) async {
    _scheduleCacheWrite();
    try {
      final envelope = await _crypto.encryptJson(note.toPlainJson());
      await _backend.push(note.id, envelope);
    } catch (_) {/* offline tolerated */}
    _scheduleAutoSync();
  }

  /// Coalesce rapid edits into a single full-cache rewrite. The cache is
  /// purely a local performance cache, so eventual consistency is fine.
  void _scheduleCacheWrite() {
    _cacheWriteTimer?.cancel();
    _cacheWriteTimer = Timer(const Duration(milliseconds: 300), () {
      _cacheWriteInFlight = _writeCache();
    });
  }

  /// Debounced background sync used after every local create/update/delete.
  /// Coalesces rapid successive edits into a single sync.
  void _scheduleAutoSync() {
    _autoSyncTimer?.cancel();
    _autoSyncTimer = Timer(_autoSyncDelay, () => unawaited(sync()));
  }

  @override
  void dispose() {
    _autoSyncTimer?.cancel();
    _cacheWriteTimer?.cancel();
    // Best-effort flush of any pending cache write.
    if (_cacheWriteTimer != null && _cacheWriteInFlight == null) {
      unawaited(_writeCache());
    }
    super.dispose();
  }

  // --- sync ---------------------------------------------------------------

  Future<void> sync() async {
    if (_syncing) return;
    _syncing = true;
    _lastSyncError = null;
    notifyListeners();
    try {
      final remote = await _backend.pullAll();
      remote.remove(_vaultDescriptorId);

      // Merge cloud tombstones into local tombstones (max timestamp wins).
      final remoteTombsEnv = remote.remove(_tombstonesDocId);
      var tombstonesChanged = false;
      if (remoteTombsEnv != null) {
        try {
          final clear = await _crypto.decryptJson(remoteTombsEnv);
          final raw = (clear['t'] as Map?)?.cast<String, dynamic>() ?? {};
          for (final e in raw.entries) {
            final ts = DateTime.tryParse(e.value as String);
            if (ts == null) continue;
            final existing = _tombstones[e.key];
            if (existing == null || ts.isAfter(existing)) {
              _tombstones[e.key] = ts;
              tombstonesChanged = true;
            }
          }
        } catch (_) {/* skip */}
      }

      // Prune very old tombstones.
      final cutoff = DateTime.now().subtract(_tombstoneTtl);
      _tombstones.removeWhere((_, ts) {
        if (ts.isBefore(cutoff)) {
          tombstonesChanged = true;
          return true;
        }
        return false;
      });

      // Apply tombstones to local notes (delete locally if remote killed it
      // after the local copy was last updated).
      for (final entry in _tombstones.entries) {
        final n = _notes[entry.key];
        if (n != null && !n.updatedAt.isAfter(entry.value)) {
          _notes.remove(entry.key);
        }
      }
      // ...and skip resurrecting tombstoned notes from the remote snapshot.
      remote.removeWhere((id, env) {
        final ts = _tombstones[id];
        return ts != null;
      });

      if (_reconcileDeletionsAgainst(remote)) {
        tombstonesChanged = true;
      }

      await _applyRemote(remote);

      // Push anything local that the remote doesn't have, or that the
      // remote has an older version of. Skip notes that are tombstoned
      // newer than the local edit.
      for (final n in _notes.values) {
        final ts = _tombstones[n.id];
        if (ts != null) continue;
        final r = remote[n.id];
        var shouldPush = r == null;
        if (r != null) {
          // Remote exists; push only if our local copy is strictly newer.
          final clear = await _crypto.decryptJson(r);
          final remoteNote = Note.fromPlainJson(n.id, clear);
          if (n.updatedAt.isAfter(remoteNote.updatedAt)) {
            shouldPush = true;
          }
        }
        if (shouldPush) {
          await _backend.push(n.id, await _crypto.encryptJson(n.toPlainJson()));
        }
      }

      if (tombstonesChanged) {
        await _writeTombstones();
        await _pushTombstones();
      }
      await _writeCache();
      _lastSync = DateTime.now();
      await _storage.write(
        key: _lastSyncKey,
        value: _lastSync!.toIso8601String(),
      );
    } catch (e) {
      _lastSyncError = e.toString();
    } finally {
      _syncing = false;
      notifyListeners();
    }
  }

  /// Detect notes that were deleted on another device WITHOUT leaving a
  /// tombstone (e.g. the tombstone blob was pruned past the TTL).
  /// If we've completed at least one sync before, any local note that
  /// existed at that time and is now absent from the remote snapshot has
  /// been deleted elsewhere. Returns true if any tombstone was created.
  ///
  /// Safety net: if the remote snapshot contains *none* of our pre-existing
  /// notes (wrong account, Drive folder wiped, partial pull), refuse to
  /// auto-tombstone — that path would mass-delete the user's data.
  bool _reconcileDeletionsAgainst(Map<String, Map<String, dynamic>> remote) {
    final lastSync = _lastSync;
    if (lastSync == null) return false;
    final preExisting = _notes.values
        .where((n) => !n.updatedAt.isAfter(lastSync))
        .toList();
    if (preExisting.isEmpty) return false;
    final overlap = preExisting.where((n) => remote.containsKey(n.id)).length;
    if (overlap == 0) {
      // Snapshot doesn't look like ours; do nothing rather than wipe data.
      return false;
    }
    final missing = <String>[
      for (final n in preExisting)
        if (!remote.containsKey(n.id)) n.id,
    ];
    if (missing.isEmpty) return false;
    final now = DateTime.now();
    for (final id in missing) {
      _notes.remove(id);
      _tombstones[id] = now;
    }
    return true;
  }

  /// Decrypt and merge a snapshot of remote envelopes (no `__vault__`).
  /// Newer remote notes overwrite local; older are ignored.
  Future<void> _applyRemote(Map<String, Map<String, dynamic>> remote) async {
    for (final entry in remote.entries) {
      try {
        final clear = await _crypto.decryptJson(entry.value);
        final remoteNote = Note.fromPlainJson(entry.key, clear);
        final local = _notes[entry.key];
        if (local == null || remoteNote.updatedAt.isAfter(local.updatedAt)) {
          _notes[entry.key] = remoteNote;
        }
      } catch (_) {/* skip */}
    }
    notifyListeners();
  }
}
