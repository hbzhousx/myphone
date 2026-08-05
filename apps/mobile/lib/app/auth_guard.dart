import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class AuthGuard {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
      resetOnError: true,
    ),
  );
  static const _tokenKey = 'auth_token';
  static const _userIdKey = 'auth_user_id';
  static const _biometricEnabledKey = 'biometric_enabled';
  static const _savedPhoneKey = 'saved_phone';

  static Future<void> _reportDebug(String hypothesisId, String message, Map<String, Object?> data) async {
    if (!kDebugMode) {
      return;
    }
    final client = HttpClient();
    try {
      final request = await client.postUrl(Uri.parse('http://192.168.3.113:7777/event'));
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({
        'sessionId': 'mobile-crash',
        'runId': 'pre-fix',
        'hypothesisId': hypothesisId,
        'location': 'lib/app/auth_guard.dart',
        'msg': '[DEBUG] $message',
        'data': data,
        'ts': DateTime.now().millisecondsSinceEpoch,
      }));
      await request.close();
    } catch (_) {
    } finally {
      client.close(force: true);
    }
  }

  static Future<bool> isLoggedIn() async {
    try {
      final token = await _storage.read(key: _tokenKey);
      // #region debug-point A:secure-storage-read
      unawaited(_reportDebug('A', 'Auth token read completed', {
        'has_token': token != null && token.isNotEmpty,
      }));
      // #endregion
      return token != null && token.isNotEmpty;
    } catch (error, stack) {
      // #region debug-point A:secure-storage-read-error
      unawaited(_reportDebug('A', 'Auth token read failed', {
        'error': error.toString(),
        'stack': stack.toString(),
      }));
      // #endregion
      return false;
    }
  }

  static Future<void> saveToken(String token) async {
    try {
      await _storage.write(key: _tokenKey, value: token);
      // #region debug-point A:secure-storage-write
      unawaited(_reportDebug('A', 'Auth token write completed', {
        'token_length': token.length,
      }));
      // #endregion
    } catch (error, stack) {
      // #region debug-point A:secure-storage-write-error
      unawaited(_reportDebug('A', 'Auth token write failed', {
        'error': error.toString(),
        'stack': stack.toString(),
      }));
      // #endregion
      rethrow;
    }
  }

  static Future<void> saveUserId(String userId) async {
    await _storage.write(key: _userIdKey, value: userId);
  }

  static Future<String?> getUserId() async {
    return await _storage.read(key: _userIdKey);
  }

  static Future<void> setBiometricEnabled(bool enabled, {String? phone}) async {
    if (enabled) {
      await _storage.write(key: _biometricEnabledKey, value: '1');
      if (phone != null) {
        await _storage.write(key: _savedPhoneKey, value: phone);
      }
    } else {
      await _storage.delete(key: _biometricEnabledKey);
    }
  }

  static Future<bool> isBiometricEnabled() async {
    try {
      final v = await _storage.read(key: _biometricEnabledKey);
      return v == '1';
    } catch (_) {
      return false;
    }
  }

  static Future<String?> getSavedPhone() async {
    try {
      return await _storage.read(key: _savedPhoneKey);
    } catch (_) {
      return null;
    }
  }

  static Future<void> clearToken() async {
    try {
      await _storage.delete(key: _tokenKey);
      await _storage.delete(key: _userIdKey);
      // #region debug-point A:secure-storage-delete
      unawaited(_reportDebug('A', 'Auth token delete completed', {}));
      // #endregion
    } catch (error, stack) {
      // #region debug-point A:secure-storage-delete-error
      unawaited(_reportDebug('A', 'Auth token delete failed', {
        'error': error.toString(),
        'stack': stack.toString(),
      }));
      // #endregion
      rethrow;
    }
  }

  static Future<String?> getToken() async {
    try {
      final token = await _storage.read(key: _tokenKey);
      // #region debug-point A:secure-storage-get
      unawaited(_reportDebug('A', 'Auth token get completed', {
        'has_token': token != null && token.isNotEmpty,
      }));
      // #endregion
      return token;
    } catch (error, stack) {
      // #region debug-point A:secure-storage-get-error
      unawaited(_reportDebug('A', 'Auth token get failed', {
        'error': error.toString(),
        'stack': stack.toString(),
      }));
      // #endregion
      return null;
    }
  }
}
