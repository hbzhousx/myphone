/// Biometric authentication — Android BiometricPrompt / iOS LAContext.
library;

import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import '../../app/auth_guard.dart';

class BiometricAuth {
  static final _auth = LocalAuthentication();

  static Future<BiometricAvailability> checkAvailability() async {
    try {
      final canCheck = await _auth.canCheckBiometrics;
      if (!canCheck) return BiometricAvailability.notAvailable;
      final availableTypes = await _auth.getAvailableBiometrics();
      final isEnrolled = await _auth.isDeviceSupported();
      return BiometricAvailability.available(
        hasFingerprint: availableTypes.contains(BiometricType.fingerprint),
        hasFace: availableTypes.contains(BiometricType.face),
        isEnrolled: isEnrolled,
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
      return authenticated ? BiometricResult.success : BiometricResult.failed;
    } on PlatformException catch (e) {
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
    if (!hasToken) return BiometricResult.error('No stored credentials');
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
