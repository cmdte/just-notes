# Just Notes

A small, Google Keep–style note-taking app written in Dart/Flutter.

## Features

- **Sticky-note board** — masonry grid of colored cards. Tap a card to edit, long-press to drag-reorder. Delete from the editor's app bar.
- **End-to-end encryption** — every note is encrypted on-device with **AES-256-GCM**. The key is derived from your passphrase via **Argon2id** (19 MiB memory, 2 iterations, parallelism 1, 32-byte output — OWASP "interactive" baseline). The salt and a small verifier blob live in the platform secure storage (Android Keystore via `flutter_secure_storage`).
- **Pluggable cloud sync** — all sync goes through the [`SyncBackend`](lib/sync/sync_backend.dart) interface. Built-in backends: **Google Drive** (`appDataFolder`), **WebDAV** (Nextcloud/ownCloud/etc.), and **Local folder** (point Syncthing/Dropbox/iCloud Drive at it). Backends only ever see ciphertext (zero-knowledge).
- **Cross-device key adoption** — first device publishes a `__vault__` descriptor (salt + verifier) to the chosen backend; second device adopts it on unlock so both derive the same key from the shared passphrase.
- **Tombstones** — deletions propagate across devices via a `__tombstones__` blob (90-day TTL).
- **Change passphrase** — Settings → Change passphrase re-encrypts the entire vault and atomically swaps the descriptor.
- **Offline-first** — local plain-JSON cache (the cloud copy is the encrypted source of truth); auto-sync 800 ms after every edit; pull-to-refresh on the board.

## Project layout

```
lib/
├─ main.dart
├─ crypto/note_crypto.dart            # AES-256-GCM + Argon2id
├─ models/note.dart
├─ repository/notes_repository.dart   # in-memory state, cache, sync orchestration
├─ sync/
│  ├─ sync_backend.dart               # SyncBackend interface + LocalStubBackend
│  ├─ backend_config.dart
│  ├─ google_drive_backend.dart
│  ├─ webdav_backend.dart
│  └─ folder_backend.dart
├─ settings/app_settings.dart         # theme prefs
└─ ui/
   ├─ unlock_screen.dart
   ├─ board_screen.dart
   ├─ note_editor.dart
   ├─ settings_screen.dart
   └─ backend_picker_screen.dart
```

## Run it

```sh
flutter pub get
flutter run                                              # debug build on a connected device
flutter build apk --release --target-platform android-arm64   # release APK (arm64-v8a only)
```

## Release signing

1. Create a release keystore:
   ```sh
   keytool -genkey -v -keystore ~/keystores/just-notes-release.jks \
       -keyalg RSA -keysize 2048 -validity 10000 -alias notes
   ```
2. Copy [android/key.properties.example](android/key.properties.example) to `android/key.properties` and fill in the real path / passwords. `key.properties` is gitignored.
3. For Google Drive sync, create an OAuth 2.0 **Web** client in Google Cloud Console and an **Android** client whose SHA-1 matches the keystore from step 1. Replace `_serverClientId` in [lib/sync/google_drive_backend.dart](lib/sync/google_drive_backend.dart) with your own Web client ID.

## Plugging in a new sync backend

Implement [`SyncBackend`](lib/sync/sync_backend.dart):

```dart
abstract class SyncBackend {
  Future<Map<String, Map<String, dynamic>>> pullAll();
  Future<void> push(String id, Map<String, dynamic> envelope);
  Future<void> delete(String id);
}
```

Wire it into `buildBackend()` in the same file and add a corresponding entry to [`BackendKind`](lib/sync/backend_config.dart). The `envelope` map is opaque ciphertext — store it as-is.

## Security notes

- The passphrase **never leaves the device**; only the per-note nonce + ciphertext do.
- The verifier blob lets us reject a wrong passphrase at unlock without trying to decrypt every note.
- Lose the passphrase → data is unrecoverable. That is the point.
- The local cache (`notes_cache.json`) is plain JSON inside the OS app sandbox — by design. The authoritative encrypted copy is on the chosen backend.
