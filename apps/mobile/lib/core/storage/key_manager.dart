/// Manages the SQLCipher database encryption key (256-bit AES).
/// Stored in platform secure storage (Android Keystore / iOS Keychain).
library;

import 'dart:math';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class KeyManager {
  static const _storage = FlutterSecureStorage();
  static const _dbKeyName = 'sqlcipher_db_key';

  static Future<String> getOrCreateDbKey() async {
    final existing = await _storage.read(key: _dbKeyName);
    if (existing != null && existing.length >= 64) return existing;
    final newKey = _generateKey();
    await _storage.write(key: _dbKeyName, value: newKey);
    return newKey;
  }

  static String _generateKey() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
