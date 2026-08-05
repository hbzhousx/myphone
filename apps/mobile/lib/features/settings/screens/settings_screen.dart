import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../app/auth_guard.dart';
import '../settings_state.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          const _SectionHeader(title: 'Account'),
          FutureBuilder<String?>(
            future: AuthGuard.getUserId(),
            builder: (context, snapshot) {
              return ListTile(
                leading: const CircleAvatar(child: Icon(Icons.person)),
                title: const Text('User ID'),
                subtitle: Text(snapshot.data ?? 'Not signed in'),
              );
            },
          ),
          const Divider(),

          const _SectionHeader(title: 'Preferences'),
          SwitchListTile(
            title: const Text('Call Notifications'),
            subtitle: const Text('Show incoming call alerts'),
            value: settings.notificationsEnabled,
            onChanged: (_) =>
                ref.read(settingsProvider.notifier).toggleNotifications(),
            secondary: const Icon(Icons.notifications),
          ),
          const Divider(),

          const _SectionHeader(title: 'About'),
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('Version'),
            subtitle: Text('1.0.0 (build 1)'),
          ),
          const ListTile(
            leading: Icon(Icons.security),
            title: Text('Encryption'),
            subtitle: Text('E2E encrypted calls with X25519 + AES-256-GCM'),
          ),
          const Divider(),

          Padding(
            padding: const EdgeInsets.all(16),
            child: ElevatedButton.icon(
              onPressed: () async {
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Sign Out'),
                    content:
                        const Text('Are you sure you want to sign out?'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('Cancel')),
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text('Sign Out')),
                    ],
                  ),
                );
                if (confirm == true && context.mounted) {
                  await AuthGuard.clearToken();
                  context.go('/login');
                }
              },
              icon: const Icon(Icons.logout),
              label: const Text('Sign Out'),
              style: ElevatedButton.styleFrom(
                backgroundColor: theme.colorScheme.error,
                foregroundColor: theme.colorScheme.onError,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: Theme.of(context).colorScheme.primary,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}
