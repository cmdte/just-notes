import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

/// AES-256-GCM with a key derived from a user passphrase via Argon2id.
///
/// Argon2id parameters target the OWASP "interactive" baseline: 19 MiB of
/// memory, 2 passes, parallelism 1. Memory-hard so brute-force attacks are
/// expensive on GPUs/ASICs.
class NoteCrypto {
  NoteCrypto._(this._secretKey, this.saltB64);

  static const int _saltLen = 16;
  static const int _nonceLen = 12;

  // Argon2id parameters (RFC 9106 / OWASP recommendations).
  static const int _argonMemoryKib = 19456; // 19 MiB
  static const int _argonIterations = 2;
  static const int _argonParallelism = 1;

  static final AesGcm _aead = AesGcm.with256bits();

  final SecretKey _secretKey;
  final String saltB64;

  /// Derive a vault key from [passphrase].
  /// Pass null [saltB64] on first-time setup to generate a fresh salt.
  static Future<NoteCrypto> derive({
    required String passphrase,
    String? saltB64,
  }) async {
    final salt =
        saltB64 != null ? base64Decode(saltB64) : _randomBytes(_saltLen);

    // Argon2id is CPU + memory heavy; run it in a background isolate so the
    // UI thread stays responsive during unlock.
    final keyBytes = await compute(
      _argon2idDeriveBytes,
      _Argon2Args(passphrase: passphrase, salt: salt),
    );

    return NoteCrypto._(SecretKey(keyBytes), base64Encode(salt));
  }

  Future<Map<String, dynamic>> encryptJson(Map<String, dynamic> plain) async {
    final nonce = _randomBytes(_nonceLen);
    final box = await _aead.encrypt(
      utf8.encode(jsonEncode(plain)),
      secretKey: _secretKey,
      nonce: nonce,
    );
    final ct = Uint8List(box.cipherText.length + box.mac.bytes.length)
      ..setRange(0, box.cipherText.length, box.cipherText)
      ..setRange(box.cipherText.length,
          box.cipherText.length + box.mac.bytes.length, box.mac.bytes);

    return <String, dynamic>{
      'nonce': base64Encode(nonce),
      'ct': base64Encode(ct),
    };
  }

  Future<Map<String, dynamic>> decryptJson(
      Map<String, dynamic> envelope) async {
    final nonce = base64Decode(envelope['nonce'] as String);
    final ct = base64Decode(envelope['ct'] as String);
    const tagLen = 16;
    final cipherText = ct.sublist(0, ct.length - tagLen);
    final mac = Mac(ct.sublist(ct.length - tagLen));

    final clear = await _aead.decrypt(
      SecretBox(cipherText, nonce: nonce, mac: mac),
      secretKey: _secretKey,
    );
    return jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
  }

  static Uint8List _randomBytes(int n) {
    final rng = SecretKeyData.random(length: n);
    return Uint8List.fromList(rng.bytes);
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
