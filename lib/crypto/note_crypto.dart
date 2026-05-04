import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

/// AES-256-GCM envelope encryption.
///
/// The vault uses a two-tier key hierarchy:
///
///   * A random **DEK** (Data Encryption Key) encrypts every note.
///     Generated once at vault creation, never derived from the
///     passphrase, never changes for the lifetime of the vault.
///   * A **KEK** (Key Encryption Key) is derived from the user passphrase
///     via Argon2id and is used solely to wrap the DEK.
///
/// Consequence: changing the passphrase is an O(1) re-wrap of one tiny
/// blob — no re-encryption of notes, no possibility of leaving the cloud
/// in a half-migrated state if the network drops mid-operation.
///
/// Argon2id parameters target the OWASP "interactive" baseline: 19 MiB of
/// memory, 2 passes, parallelism 1. Memory-hard so brute-force attacks are
/// expensive on GPUs/ASICs.
class NoteCrypto {
  NoteCrypto._(this._dek);

  static const int _saltLen = 16;
  static const int _nonceLen = 12;
  static const int _dekLen = 32;
  static const int _tagLen = 16;

  // Argon2id parameters (RFC 9106 / OWASP recommendations).
  static const int _argonMemoryKib = 19456; // 19 MiB
  static const int _argonIterations = 2;
  static const int _argonParallelism = 1;

  static final AesGcm _aead = AesGcm.with256bits();

  final SecretKey _dek;

  Future<Map<String, dynamic>> encryptJson(Map<String, dynamic> plain) =>
      _encryptBytes(_dek, utf8.encode(jsonEncode(plain)));

  Future<Map<String, dynamic>> decryptJson(
      Map<String, dynamic> envelope) async {
    final clear = await _decryptBytes(_dek, envelope);
    return jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
  }

  // --- raw AEAD primitives (used by Vault for DEK wrap/unwrap) ------------

  static Future<Map<String, dynamic>> _encryptBytes(
    SecretKey key,
    List<int> plain,
  ) async {
    final nonce = _randomBytes(_nonceLen);
    final box = await _aead.encrypt(plain, secretKey: key, nonce: nonce);
    final ct = Uint8List(box.cipherText.length + box.mac.bytes.length)
      ..setRange(0, box.cipherText.length, box.cipherText)
      ..setRange(box.cipherText.length,
          box.cipherText.length + box.mac.bytes.length, box.mac.bytes);
    return <String, dynamic>{
      'nonce': base64Encode(nonce),
      'ct': base64Encode(ct),
    };
  }

  static Future<List<int>> _decryptBytes(
    SecretKey key,
    Map<String, dynamic> envelope,
  ) async {
    final nonce = base64Decode(envelope['nonce'] as String);
    final ct = base64Decode(envelope['ct'] as String);
    final cipherText = ct.sublist(0, ct.length - _tagLen);
    final mac = Mac(ct.sublist(ct.length - _tagLen));
    return _aead.decrypt(
      SecretBox(cipherText, nonce: nonce, mac: mac),
      secretKey: key,
    );
  }

  static Uint8List _randomBytes(int n) {
    final rng = SecretKeyData.random(length: n);
    return Uint8List.fromList(rng.bytes);
  }
}

/// Persistable wrapper around an encrypted DEK plus the salt needed to
/// re-derive the KEK. This is the only secret artifact synced to the
/// cloud — and even it cannot be opened without the passphrase.
@immutable
class VaultDescriptor {
  const VaultDescriptor({required this.saltB64, required this.wrappedDek});

  final String saltB64;
  final Map<String, dynamic> wrappedDek;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'v': 1,
        'salt': saltB64,
        'dek': wrappedDek,
      };

  static VaultDescriptor? fromJson(Map<String, dynamic>? raw) {
    if (raw == null) return null;
    final salt = raw['salt'];
    final dek = raw['dek'];
    if (salt is! String || dek is! Map) return null;
    return VaultDescriptor(
      saltB64: salt,
      wrappedDek: dek.cast<String, dynamic>(),
    );
  }
}

/// Vault lifecycle helpers: create, open, re-wrap.
class Vault {
  Vault._();

  /// First-time setup: generate a random DEK and wrap it with a KEK
  /// derived from [passphrase] + a fresh salt.
  static Future<({NoteCrypto crypto, VaultDescriptor descriptor})> create(
    String passphrase,
  ) async {
    final salt = NoteCrypto._randomBytes(NoteCrypto._saltLen);
    final dekBytes = NoteCrypto._randomBytes(NoteCrypto._dekLen);
    final kek = await _deriveKek(passphrase: passphrase, salt: salt);
    final wrapped = await NoteCrypto._encryptBytes(kek, dekBytes);
    return (
      crypto: NoteCrypto._(SecretKey(dekBytes)),
      descriptor: VaultDescriptor(
        saltB64: base64Encode(salt),
        wrappedDek: wrapped,
      ),
    );
  }

  /// Open an existing vault: derive the KEK from [passphrase] and the
  /// salt in [descriptor], then unwrap the DEK.
  ///
  /// Returns null when the passphrase is wrong — AES-GCM's auth tag
  /// detects this without needing a separate verifier blob.
  static Future<NoteCrypto?> open(
    String passphrase,
    VaultDescriptor descriptor,
  ) async {
    final salt = base64Decode(descriptor.saltB64);
    final kek = await _deriveKek(passphrase: passphrase, salt: salt);
    try {
      final dekBytes =
          await NoteCrypto._decryptBytes(kek, descriptor.wrappedDek);
      return NoteCrypto._(SecretKey(dekBytes));
    } catch (_) {
      return null;
    }
  }

  /// Produce a fresh descriptor that wraps the same DEK with a KEK
  /// derived from [newPassphrase] and a brand-new salt. The returned
  /// descriptor can be persisted atomically; notes do not need to be
  /// touched.
  static Future<VaultDescriptor> rewrap(
    NoteCrypto crypto,
    String newPassphrase,
  ) async {
    final dekBytes = await crypto._dek.extractBytes();
    final salt = NoteCrypto._randomBytes(NoteCrypto._saltLen);
    final kek = await _deriveKek(passphrase: newPassphrase, salt: salt);
    final wrapped = await NoteCrypto._encryptBytes(kek, dekBytes);
    return VaultDescriptor(
      saltB64: base64Encode(salt),
      wrappedDek: wrapped,
    );
  }

  static Future<SecretKey> _deriveKek({
    required String passphrase,
    required List<int> salt,
  }) async {
    // Argon2id is CPU + memory heavy; run it in a background isolate so
    // the UI thread stays responsive during unlock.
    final keyBytes = await compute(
      _argon2idDeriveBytes,
      _Argon2Args(passphrase: passphrase, salt: salt),
    );
    return SecretKey(keyBytes);
  }
}

// Top-level helper for compute() — must be a top-level function.

class _Argon2Args {
  const _Argon2Args({required this.passphrase, required this.salt});
  final String passphrase;
  final List<int> salt;
}

Future<List<int>> _argon2idDeriveBytes(_Argon2Args a) async {
  final algo = Argon2id(
    parallelism: NoteCrypto._argonParallelism,
    memory: NoteCrypto._argonMemoryKib,
    iterations: NoteCrypto._argonIterations,
    hashLength: 32,
  );
  final key = await algo.deriveKey(
    secretKey: SecretKey(utf8.encode(a.passphrase)),
    nonce: a.salt,
  );
  return key.extractBytes();
}
