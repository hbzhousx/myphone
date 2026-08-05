/// Biometric authentication — Android BiometricPrompt / iOS LAContext.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import '../../app/auth_guard.dart';

class BiometricAuth {
  static final _auth = LocalAuthentication();

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
        'location': 'lib/features/auth/biometric_auth.dart',
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

  static Future<BiometricAvailability> checkAvailability() async {
    try {
      // canCheckBiometrics can be false before the first authenticate() call
      // or before permission is granted, even though hardware exists. Use
      // isDeviceSupported + available types for capability, and only treat
      // a hard "not supported" as unavailable.
      final deviceSupported = await _auth.isDeviceSupported();
      if (!deviceSupported) {
        return BiometricAvailability.notAvailable;
      }
      final availableTypes = await _auth.getAvailableBiometrics();
      final canCheck = await _auth.canCheckBiometrics;
      return BiometricAvailability.available(
        hasFingerprint: availableTypes.contains(BiometricType.fingerprint),
        hasFace: availableTypes.contains(BiometricType.face),
        // True only when at least one biometric is enrolled and usable.
        isEnrolled: canCheck,
      );
    } on PlatformException {
      return BiometricAvailability.notAvailable;
    }
  }

  static Future<BiometricResult> authenticate({
    required String reason,
    bool stickyAuth = true,
  }) async {
    try {
      final authenticated = await _auth.authenticate(
        localizedReason: reason,
        options: AuthenticationOptions(
          stickyAuth: stickyAuth,
          biometricOnly: true,
        ),
      );
      // #region debug-point C:biometric-auth-result
      unawaited(_reportDebug('C', 'Biometric authenticate completed', {
        'authenticated': authenticated,
      }));
      // #endregion
      return authenticated ? BiometricResult.success : BiometricResult.failed;
    } on PlatformException catch (e) {
      // #region debug-point C:biometric-auth-error
      unawaited(_reportDebug('C', 'Biometric authenticate failed', {
        'code': e.code,
        'message': e.message,
      }));
      // #endregion
      switch (e.code) {
        case 'lockedOut':
          return BiometricResult.lockedOut;
        case 'lockoutPermanent':
          return BiometricResult.lockedOutPermanent;
        default:
          return BiometricResult.error(e.message ?? 'Unknown error');
      }
    }
  }

  static Future<BiometricResult> biometricLogin() async {
    final hasToken = await AuthGuard.isLoggedIn();
    if (!hasToken) {
      // #region debug-point C:biometric-login-no-token
      unawaited(_reportDebug('C', 'Biometric login skipped due to missing token', {}));
      // #endregion
      return BiometricResult.error('No stored credentials');
    }
    return authenticate(reason: 'Authenticate to unlock MyPhone');
  }
}

class BiometricAvailability {
  final bool isAvailable;
  final bool hasFingerprint;
  final bool hasFace;
  final bool isEnrolled;

  const BiometricAvailability._({
    required this.isAvailable,
    required this.hasFingerprint,
    required this.hasFace,
    required this.isEnrolled,
  });

  static const notAvailable = BiometricAvailability._(
    isAvailable: false, hasFingerprint: false, hasFace: false, isEnrolled: false,
  );

  static BiometricAvailability available({
    required bool hasFingerprint,
    required bool hasFace,
    required bool isEnrolled,
  }) {
    return BiometricAvailability._(
      isAvailable: true, hasFingerprint: hasFingerprint,
      hasFace: hasFace, isEnrolled: isEnrolled,
    );
  }
}

enum BiometricResultType { success, failed, lockedOut, lockedOutPermanent, error }

class BiometricResult {
  final BiometricResultType type;
  final String? message;

  const BiometricResult._(this.type, [this.message]);

  static const success = BiometricResult._(BiometricResultType.success);
  static const failed = BiometricResult._(BiometricResultType.failed);
  static const lockedOut = BiometricResult._(BiometricResultType.lockedOut);
  static const lockedOutPermanent = BiometricResult._(BiometricResultType.lockedOutPermanent);
  static BiometricResult error(String msg) => BiometricResult._(BiometricResultType.error, msg);

  bool get isSuccess => type == BiometricResultType.success;
}
