import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../biometric_auth.dart';
import '../../../app/auth_guard.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});
  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  bool _biometricAvailable = false;
  bool _hasStoredCredentials = false;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _checkBiometric();
  }

  Future<void> _checkBiometric() async {
    final availability = await BiometricAuth.checkAvailability();
    final hasToken = await AuthGuard.isLoggedIn();
    final biometricBound = await AuthGuard.isBiometricEnabled();
    if (mounted) {
      setState(() {
        _biometricAvailable = availability.isAvailable;
        // Show the fingerprint button if we have a valid token, OR if the
        // user previously bound a fingerprint (persisted across sign-out).
        _hasStoredCredentials = hasToken || biometricBound;
        _isLoading = false;
      });
      if (_biometricAvailable && hasToken) {
        _tryBiometricLogin();
      }
    }
  }

  Future<void> _tryBiometricLogin() async {
    final result = await BiometricAuth.biometricLogin();
    if (!mounted) return;
    if (result.isSuccess) {
      final hasToken = await AuthGuard.isLoggedIn();
      if (hasToken) {
        context.go('/dialer');
      } else {
        // Token was cleared (signed out) but fingerprint is bound —
        // route to password login prefilled with the saved phone number.
        final savedPhone = await AuthGuard.getSavedPhone();
        context.go('/phone-login', extra: savedPhone);
      }
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.message ?? 'Biometric authentication failed')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.phone_android_rounded, size: 80, color: theme.colorScheme.primary),
              const SizedBox(height: 16),
              Text('MyPhone', style: theme.textTheme.headlineLarge?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text('Encrypted calls, anywhere.', style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              const SizedBox(height: 64),
              if (_biometricAvailable && _hasStoredCredentials) ...[
                SizedBox(
                  width: 80, height: 80,
                  child: ElevatedButton(
                    onPressed: _tryBiometricLogin,
                    style: ElevatedButton.styleFrom(shape: const CircleBorder(), padding: EdgeInsets.zero),
                    child: const Icon(Icons.fingerprint, size: 40),
                  ),
                ),
                const SizedBox(height: 24),
                const Row(children: [Expanded(child: Divider()), Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: Text('or')), Expanded(child: Divider())]),
                const SizedBox(height: 24),
              ],
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () => context.go('/phone-login'),
                  child: const Text('Sign In with Phone'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
