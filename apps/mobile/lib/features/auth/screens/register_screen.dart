import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:convert/convert.dart';
import '../../../app/auth_guard.dart';
import '../../../core/crypto/crypto_manager.dart';
import '../../../core/network/api_client.dart';
import '../../../core/storage/database.dart';
import '../biometric_auth.dart';

class RegisterScreen extends ConsumerStatefulWidget {
  const RegisterScreen({super.key});
  @override
  ConsumerState<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends ConsumerState<RegisterScreen> {
  final _phoneController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoading = false;
  String? _error;

  @override
  void dispose() {
    _phoneController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _register() async {
    final phone = _phoneController.text.trim();
    final password = _passwordController.text;
    if (phone.isEmpty || password.isEmpty) {
      setState(() => _error = 'Please fill all fields');
      return;
    }
    // Password must be exactly 6 digits.
    if (!RegExp(r'^\d{6}$').hasMatch(password)) {
      setState(() => _error = 'Password must be 6 digits');
      return;
    }
    setState(() { _isLoading = true; _error = null; });
    try {
      final identityKey = await CryptoManager.generateIdentityKeyPair();
      final exported = await CryptoManager.exportKeyPair(identityKey);
      final identityPublicKey = hex.encode(exported.publicKey);

      final client = ApiClient();
      final response = await client.register(
        phoneNumber: phone,
        password: password,
        identityPublicKey: identityPublicKey,
      );

      final token = response['token'] as String;
      final userId = response['user_id'] as String;
      await AuthGuard.saveToken(token);
      await AuthGuard.saveUserId(userId);

      await DatabaseManager.instance.storeKey('e2ee_identity_x25519_private', exported.privateKey);
      await DatabaseManager.instance.storeKey('e2ee_identity_x25519_public', exported.publicKey);

      if (mounted) {
        await _offerBiometricSetup();
        if (mounted) context.go('/dialer');
      }
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// After successful registration, offer to bind biometric auth so the user
  /// can unlock the app with a fingerprint on next launch.
  Future<void> _offerBiometricSetup() async {
    if (!mounted) return;
    final availability = await BiometricAuth.checkAvailability();
    if (!mounted || !availability.isAvailable || !availability.isEnrolled) {
      // No biometric hardware or no enrolled fingerprint — skip the prompt.
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Enable Fingerprint Unlock?'),
        content: const Text('Bind your fingerprint so you can unlock MyPhone '
            'without entering your password on next launch.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Not Now')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Enable')),
        ],
      ),
    );
    if (confirmed == true) {
      final result = await BiometricAuth.authenticate(
        reason: 'Authenticate to bind fingerprint',
      );
      if (result.isSuccess) {
        // Persist the biometric binding so the login screen can offer
        // fingerprint unlock even after the token is cleared or the app
        // is reinstalled (secure storage is retained on update).
        await AuthGuard.setBiometricEnabled(true,
            phone: _phoneController.text.trim());
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result.isSuccess
                ? 'Fingerprint bound! You can unlock with your fingerprint next time.'
                : 'Fingerprint binding skipped.'),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Register')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 24),
              Icon(Icons.lock_outline, size: 48, color: theme.colorScheme.primary),
              const SizedBox(height: 32),
              TextField(
                controller: _phoneController,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(labelText: 'Phone Number', hintText: '+1 234 567 8900', prefixIcon: Icon(Icons.phone)),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _passwordController,
                obscureText: true,
                keyboardType: TextInputType.number,
                maxLength: 6,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                  labelText: '6-digit Password',
                  counterText: '',
                  prefixIcon: Icon(Icons.lock),
                ),
              ),
              const SizedBox(height: 24),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
                ),
              ElevatedButton(
                onPressed: _isLoading ? null : _register,
                child: _isLoading
                    ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Create Account'),
              ),
              const SizedBox(height: 16),
              TextButton(
                onPressed: () => context.go('/phone-login'),
                child: const Text('Already have an account? Sign In'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
