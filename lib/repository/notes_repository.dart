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
    this._tagsFile,
    this._dirtyFile,
    this._cfg,
  );

  static const _descriptorStorageKey = 'vault_descriptor_json';
  static const _rememberedPassKey = 'vault_pass_remembered';
  static const _backendCfgKey = 'backend_config_json';
  static const _lastSyncKey = 'vault_last_sync_iso';
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
  final File _tagsFile;
  final File _dirtyFile;
  final _uuid = const Uuid();

  final Map<String, Note> _notes = <String, Note>{};
  final Map<String, DateTime> _tombstones = <String, DateTime>{};
  /// Last-known opaque version tag per remote id. Drives delta sync —
  /// only ids whose tag changed between syncs are re-downloaded.
  final Map<String, String> _remoteTags = <String, String>{};
  /// Notes that have local edits not yet acknowledged by the backend.
  /// Persisted so offline edits survive a restart and get pushed on the
  /// next successful sync.
  final Set<String> _dirty = <String>{};
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
      (await _storage.read(key: _descriptorStorageKey)) != null;

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

    // Try to use the locally cached vault descriptor first. Only reach
    // out to the cloud backend if there is no local descriptor (i.e.
    // first-time setup on a new device that needs to adopt the vault from
    // another device). This avoids touching GoogleSignIn on every app
    // launch.
    SyncBackend? backend;
    VaultDescriptor? descriptor;
    var backendReachable = false;

    final localRaw = await _storage.read(key: _descriptorStorageKey);
    if (localRaw != null) {
      descriptor = VaultDescriptor.fromJson(
        jsonDecode(localRaw) as Map<String, dynamic>,
      );
    }

    if (descriptor == null && cfg.kind != BackendKind.stub) {
      backend = await buildBackend(cfg, silent: true);
      if (backend != null) {
        try {
          descriptor =
              VaultDescriptor.fromJson(await backend.pullOne(_vaultDescriptorId));
          backendReachable = true;
        } catch (_) {/* offline tolerated */}
      }
    }

    NoteCrypto crypto;
    var freshlyCreated = false;
    if (descriptor == null) {
      // First-time setup on this device with no cloud descriptor: mint a
      // brand-new vault.
      final created = await Vault.create(passphrase);
      crypto = created.crypto;
      descriptor = created.descriptor;
      freshlyCreated = true;
    } else {
      final opened = await Vault.open(passphrase, descriptor);
      if (opened == null) {
        return (repo: null, error: 'Incorrect passphrase.');
      }
      crypto = opened;
    }

    // Persist the descriptor locally so future unlocks succeed offline.
    await _storage.write(
      key: _descriptorStorageKey,
      value: jsonEncode(descriptor.toJson()),
    );

    if (remember) {
      await _storage.write(key: _rememberedPassKey, value: passphrase);
    } else {
      await _storage.delete(key: _rememberedPassKey);
    }

    backend ??= await buildBackend(cfg, silent: true) ?? await LocalStubBackend.create();

    // Publish the descriptor if this device just minted one.
    if (cfg.kind != BackendKind.stub && freshlyCreated && backendReachable) {
      try {
        await backend.push(_vaultDescriptorId, descriptor.toJson());
      } catch (_) {/* offline tolerated */}
    }

    final dir = await getApplicationSupportDirectory();
    final cacheFile = File('${dir.path}/notes_cache.json');
    if (!await cacheFile.exists()) await cacheFile.writeAsString('{}');
    final tombstonesFile = File('${dir.path}/tombstones.json');
    if (!await tombstonesFile.exists()) await tombstonesFile.writeAsString('{}');
    final tagsFile = File('${dir.path}/remote_tags.json');
    if (!await tagsFile.exists()) await tagsFile.writeAsString('{}');
    final dirtyFile = File('${dir.path}/dirty_ids.json');
    if (!await dirtyFile.exists()) await dirtyFile.writeAsString('[]');

    final repo = NotesRepository._(
      crypto,
      backend,
      cacheFile,
      tombstonesFile,
      tagsFile,
      dirtyFile,
      cfg,
    );
    await repo._loadTombstones();
    await repo._loadFromCache();
    await repo._loadLastSync();
    await repo._loadRemoteTags();
    await repo._loadDirty();

    return (repo: repo, error: null);
  }

  // --- backend switching --------------------------------------------------

  /// Persist a new backend config and reconnect.
  /// If the new backend already holds a vault descriptor (because another
  /// device pushed it), adopt that descriptor: unwrap its DEK with the
  /// remembered passphrase so notes on the new backend become readable.
  Future<({bool ok, String? error})> setBackend(
    BackendConfig cfg, {
    bool wipeCurrent = false,
  }) async {
    if (wipeCurrent && _backend is! LocalStubBackend) {
      try {
        await _backend.deleteAll();
      } catch (e) {/* best effort */}
    }

    await _storage.write(key: _backendCfgKey, value: cfg.toJsonString());
    final newBackend = await buildBackend(cfg);
    if (newBackend == null) {
      _cfg = cfg;
      notifyListeners();
      return (ok: false, error: 'Could not connect to backend.');
    }

    if (cfg.kind != BackendKind.stub) {
      try {
        // Switching backends invalidates any cached delta-sync state from
        // the previous backend.
        _remoteTags.clear();
        await _writeRemoteTags();

        final cloudDescriptor = VaultDescriptor.fromJson(
          await newBackend.pullOne(_vaultDescriptorId),
        );

        if (cloudDescriptor != null) {
          // Cloud already has a vault. Try to unwrap its DEK with the
          // remembered passphrase. If we don't have one cached, the user
          // must re-enter it via the unlock flow.
          final pass = await _storage.read(key: _rememberedPassKey);
          if (pass == null) {
            return (
              ok: false,
              error: 'Re-enter passphrase to switch vaults.',
            );
          }
          final adopted = await Vault.open(pass, cloudDescriptor);
          if (adopted == null) {
            return (
              ok: false,
              error: 'Cloud vault has a different passphrase.',
            );
          }
          _crypto = adopted;
          await _storage.write(
            key: _descriptorStorageKey,
            value: jsonEncode(cloudDescriptor.toJson()),
          );
        }

        _backend = newBackend;
        _cfg = cfg;

        // Push our descriptor if the cloud doesn't have one.
        if (cloudDescriptor == null) {
          final localRaw = await _storage.read(key: _descriptorStorageKey);
          if (localRaw != null) {
            try {
              await _backend.push(
                _vaultDescriptorId,
                jsonDecode(localRaw) as Map<String, dynamic>,
              );
            } catch (_) {/* offline tolerated */}
          }
        }

        // Mark every local note dirty so the next sync pushes them all
        // up to the new backend.
        _dirty.addAll(_notes.keys);
        await _writeDirty();
      } catch (e) {
        notifyListeners();
        return (ok: false, error: 'Sync failed: $e');
      }
    } else {
      _backend = newBackend;
      _cfg = cfg;
      
      // When disconnecting a backend (switching to Local folder backend or null),
      // we must mark everything dirty so it saves to the new location instead
      // of getting dropped.
      _dirty.addAll(_notes.keys);
      await _writeDirty();
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

  /// Change the vault passphrase.
  ///
  /// Thanks to envelope encryption (DEK/KEK), this is an atomic O(1)
  /// operation: the DEK is unchanged, only the small wrapped-DEK
  /// descriptor is re-keyed and re-published. Notes are never touched, so
  /// a network drop mid-operation cannot corrupt the vault.
  ///
  /// Returns null on success, or a user-facing error message.
  Future<String?> changePassphrase({
    required String oldPass,
    required String newPass,
  }) async {
    if (newPass.isEmpty) return 'New passphrase cannot be empty.';

    // 1. Verify the old passphrase by re-opening the current descriptor.
    final storedRaw = await _storage.read(key: _descriptorStorageKey);
    if (storedRaw == null) return 'Vault is not initialized.';
    final current = VaultDescriptor.fromJson(
      jsonDecode(storedRaw) as Map<String, dynamic>,
    );
    if (current == null) return 'Vault descriptor is corrupt.';
    if (await Vault.open(oldPass, current) == null) {
      return 'Current passphrase is incorrect.';
    }

    // 2. Re-wrap the existing DEK with a KEK derived from the new
    //    passphrase + a fresh salt.
    final newDescriptor = await Vault.rewrap(_crypto, newPass);

    // 3. Publish the new descriptor (atomic from the cloud's POV).
    if (_cfg.kind != BackendKind.stub) {
      try {
        await _backend.push(_vaultDescriptorId, newDescriptor.toJson());
      } catch (e) {
        return 'Could not publish new descriptor: $e';
      }
    }

    // 4. Persist the new descriptor locally.
    await _storage.write(
      key: _descriptorStorageKey,
      value: jsonEncode(newDescriptor.toJson()),
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

  Future<void> _loadRemoteTags() async {
    try {
      final raw = await _tagsFile.readAsString();
      if (raw.trim().isEmpty) return;
      final data = jsonDecode(raw) as Map<String, dynamic>;
      _remoteTags
        ..clear()
        ..addAll(data.map((k, v) => MapEntry(k, v as String)));
    } catch (_) {/* ignore */}
  }

  Future<void> _writeRemoteTags() async {
    await _tagsFile.writeAsString(jsonEncode(_remoteTags), flush: true);
  }

  Future<void> _loadDirty() async {
    try {
      final raw = await _dirtyFile.readAsString();
      if (raw.trim().isEmpty) return;
      final list = (jsonDecode(raw) as List).cast<String>();
      _dirty
        ..clear()
        ..addAll(list);
    } catch (_) {/* ignore */}
  }

  Future<void> _writeDirty() async {
    await _dirtyFile.writeAsString(jsonEncode(_dirty.toList()), flush: true);
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
    _markDirty(note.id);
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
    if (from == null || !_notes.containsKey(toId)) return;

    final ordered = notes.toList();
    ordered.removeWhere((n) => n.id == fromId);
    final targetIdx = ordered.indexWhere((n) => n.id == toId);
    if (targetIdx < 0) return;

    // Use fractional midpoint ordering so only the moved note gets
    // mutated and pushed. Re-densifying the entire list forces O(N)
    // sequential network pushes on every single drag-and-drop.
    //
    // Semantics: `from` lands immediately before `to`, i.e. between
    // `ordered[targetIdx - 1]` and `ordered[targetIdx]` (= `to`).
    final double newOrder;
    if (targetIdx == 0) {
      newOrder = ordered.first.order - 1.0;
    } else {
      newOrder =
          (ordered[targetIdx - 1].order + ordered[targetIdx].order) / 2.0;
    }

    from.order = newOrder;
    from.updatedAt = DateTime.now();

    _markDirty(from.id);
    notifyListeners();
    // Don't block the UI on disk + network.
    unawaited(_persist(from));
  }

  /// Move [fromId] to the given [targetIndex] in the sorted list.
  /// Used for live drag-to-reorder.
  Future<void> reorderToIndex(String fromId, int targetIndex) async {
    final from = _notes[fromId];
    if (from == null) return;

    final ordered = notes.toList();
    final currentIdx = ordered.indexWhere((n) => n.id == fromId);
    if (currentIdx < 0 || currentIdx == targetIndex) return;

    ordered.removeAt(currentIdx);
    final insertIdx = targetIndex.clamp(0, ordered.length);

    final double newOrder;
    if (ordered.isEmpty) {
      newOrder = 0.0;
    } else if (insertIdx == 0) {
      newOrder = ordered.first.order - 1.0;
    } else if (insertIdx >= ordered.length) {
      newOrder = ordered.last.order + 1.0;
    } else {
      newOrder =
          (ordered[insertIdx - 1].order + ordered[insertIdx].order) / 2.0;
    }

    from.order = newOrder;
    from.updatedAt = DateTime.now();

    _markDirty(from.id);
    notifyListeners();
    // Don't block the UI on disk + network.
    unawaited(_persist(from));
  }

  Future<void> update(Note note) async {
    note.updatedAt = DateTime.now();
    _notes[note.id] = note;
    _markDirty(note.id);
    notifyListeners();
    // Don't block the UI on disk + network.
    unawaited(_persist(note));
  }

  Future<void> delete(String id) async {
    _notes.remove(id);
    _tombstones[id] = DateTime.now();
    _clearDirty(id);
    _remoteTags.remove(id);
    notifyListeners();
    _scheduleCacheWrite();
    unawaited(_writeTombstones());
    unawaited(_writeRemoteTags());
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
      _clearDirty(note.id);
    } catch (_) {/* offline tolerated, retried via _dirty */}
    _scheduleAutoSync();
  }

  void _markDirty(String id) {
    _dirty.add(id);
    unawaited(_writeDirty());
  }

  void _clearDirty(String id) {
    if (_dirty.remove(id)) unawaited(_writeDirty());
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
      // 1. Cheap "what's out there?" call — no payloads.
      final manifest = await _backend.pullManifest();

      // 2. Tombstones blob: re-pull only when its tag changed.
      var tombstonesChanged = false;
      final remoteTombsTag = manifest[_tombstonesDocId];
      if (remoteTombsTag != null &&
          _remoteTags[_tombstonesDocId] != remoteTombsTag) {
        final remoteTombsEnv = await _backend.pullOne(_tombstonesDocId);
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
            if (_tombstones.keys.any((id) => !raw.containsKey(id))) {
              tombstonesChanged = true;
            }
            _remoteTags[_tombstonesDocId] = remoteTombsTag;
          } catch (_) {/* skip */}
        }
      } else if (remoteTombsTag == null && _tombstones.isNotEmpty) {
        tombstonesChanged = true;
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
          _clearDirty(entry.key);
        }
      }

      // 3. Build the set of "real" remote ids (filter out our control docs)
      //    and detect deletions that came in without a tombstone.
      final remoteNoteIds = manifest.keys
          .where((id) => id != _vaultDescriptorId && id != _tombstonesDocId)
          .toSet();
      // Tombstoned ids should not be resurrected even if the cloud blob
      // still happens to exist. This means we deleted it while offline.
      // We should delete the orphaned note file and re-push our tombstones.
      final garbageIds = remoteNoteIds.where((id) => _tombstones.containsKey(id)).toList();
      for (final id in garbageIds) {
        try {
          await _backend.delete(id);
        } catch (_) {}
        remoteNoteIds.remove(id);
        tombstonesChanged = true;
      }

      if (_reconcileDeletionsAgainst(remoteNoteIds)) {
        tombstonesChanged = true;
      }

      // 4. Pull only what changed since last sync.
      final toPull = <String>[
        for (final id in remoteNoteIds)
          if (_remoteTags[id] != manifest[id]) id,
      ];
      final pulled = <String, Map<String, dynamic>>{};
      for (final id in toPull) {
        final env = await _backend.pullOne(id);
        if (env != null) pulled[id] = env;
      }
      await _applyRemote(pulled);
      // Update the tag cache for everything we just pulled.
      for (final id in pulled.keys) {
        final tag = manifest[id];
        if (tag != null) _remoteTags[id] = tag;
      }
      // Drop tag entries for ids that no longer exist remotely.
      _remoteTags.removeWhere(
        (id, _) =>
            id != _tombstonesDocId &&
            id != _vaultDescriptorId &&
            !manifest.containsKey(id),
      );

      // 5. Push every dirty note (notes with unflushed local edits) plus
      //    any local note the cloud doesn't have yet.
      final toPush = <String>{
        ..._dirty,
        for (final id in _notes.keys)
          if (!manifest.containsKey(id)) id,
      };
      for (final id in toPush) {
        final n = _notes[id];
        if (n == null) {
          _clearDirty(id);
          continue;
        }
        if (_tombstones.containsKey(id)) continue;
        try {
          await _backend.push(id, await _crypto.encryptJson(n.toPlainJson()));
          _clearDirty(id);
          // Tag is unknown until next manifest pull; leave it absent so the
          // next sync re-fetches the canonical tag (one extra pull per
          // changed note — still much cheaper than full sync).
          _remoteTags.remove(id);
        } catch (_) {/* offline tolerated; stays dirty */}
      }

      if (tombstonesChanged) {
        await _writeTombstones();
        await _pushTombstones();
      }
      await _writeRemoteTags();
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
  /// existed at that time and is now absent from the remote manifest has
  /// been deleted elsewhere. Returns true if any tombstone was created.
  ///
  /// Safety net: if the remote manifest contains *none* of our pre-existing
  /// notes (wrong account, Drive folder wiped, partial pull), refuse to
  /// auto-tombstone — that path would mass-delete the user's data.
  bool _reconcileDeletionsAgainst(Set<String> remoteIds) {
    final lastSync = _lastSync;
    if (lastSync == null) return false;
    final preExisting = _notes.values
        .where((n) => !n.updatedAt.isAfter(lastSync))
        .toList();
    if (preExisting.isEmpty) return false;
    final overlap = preExisting.where((n) => remoteIds.contains(n.id)).length;
    if (overlap == 0) {
      // Manifest doesn't look like ours; do nothing rather than wipe data.
      return false;
    }
    final missing = <String>[
      for (final n in preExisting)
        if (!remoteIds.contains(n.id)) n.id,
    ];
    if (missing.isEmpty) return false;
    final now = DateTime.now();
    for (final id in missing) {
      _notes.remove(id);
      _tombstones[id] = now;
      _clearDirty(id);
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
          _clearDirty(entry.key);
        }
      } catch (_) {/* skip */}
    }
    notifyListeners();
  }
}
