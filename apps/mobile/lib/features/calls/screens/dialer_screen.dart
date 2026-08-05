import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/storage/database.dart';
import '../call_state.dart';

class DialerScreen extends ConsumerStatefulWidget {
  const DialerScreen({super.key});
  @override
  ConsumerState<DialerScreen> createState() => _DialerScreenState();
}

class _DialerScreenState extends ConsumerState<DialerScreen> with WidgetsBindingObserver {
  final _historyKey = GlobalKey<_RecentCallsListState>();
  int _lastCallCount = -1;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _historyKey.currentState?.refresh();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Kick off WebSocket signaling connection so we can receive incoming calls.
    final call = ref.watch(callStateProvider);
    final currentCount = ref.watch(callCountProvider);

    // Refresh history when call count changes (a call ended).
    if (currentCount != _lastCallCount) {
      _lastCallCount = currentCount;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _historyKey.currentState?.refresh();
      });
    }

    return Scaffold(
      appBar: AppBar(title: const Text('MyPhone')),
      body: Column(
        children: [
          Expanded(child: _RecentCallsList(key: _historyKey)),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _ActionButton(icon: Icons.contacts, label: 'Contacts', onTap: () => context.push('/contacts')),
                  _ActionButton(icon: Icons.dialpad, label: 'Keypad', onTap: () => context.push('/keypad')),
                  _ActionButton(icon: Icons.history, label: 'Recent', onTap: () {}),
                  _ActionButton(icon: Icons.settings, label: 'Settings', onTap: () => context.push('/settings')),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _ActionButton({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 28, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 4),
            Text(label, style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

class _RecentCallsList extends StatefulWidget {
  const _RecentCallsList({super.key});
  @override
  State<_RecentCallsList> createState() => _RecentCallsListState();
}

class _RecentCallsListState extends State<_RecentCallsList> with WidgetsBindingObserver {
  List<Map<String, dynamic>> _calls = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadCalls();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _loadCalls();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _loadCalls() async {
    try {
      final calls = await DatabaseManager.instance.getCallHistory();
      // Enrich each entry with the contact's display name if we have a
      // matching contact (by contact_id), so recently added contacts show
      // their name instead of the raw number/UUID.
      for (final call in calls) {
        final contactId = call['contact_id'] as String?;
        if (contactId == null) continue;
        try {
          final contact = await DatabaseManager.instance.getContact(contactId);
          if (contact != null) {
            final name = contact['display_name'] as String?;
            if (name != null && name.isNotEmpty) {
              call['contact_name'] = name;
            }
          }
        } catch (_) {}
      }
      if (mounted) setState(() { _calls = calls; _loading = false; });
    } catch (e) {
      debugPrint('[DIALER] _loadCalls failed: $e');
      if (mounted) setState(() { _loading = false; });
    }
  }

  /// Called from parent when user navigates back after a call.
  void refresh() => _loadCalls();

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_calls.isEmpty) return const Center(child: Text('No recent calls', style: TextStyle(color: Colors.grey)));
    return ListView.builder(
      itemCount: _calls.length,
      itemBuilder: (context, index) {
        final call = _calls[index];
        final direction = call['direction'] as String;
        final isMissed = call['status'] == 'missed';
        return ListTile(
          leading: Icon(
            direction == 'incoming' ? Icons.call_received : Icons.call_made,
            color: isMissed ? Colors.red : Colors.green,
          ),
          title: Text(call['contact_name'] as String? ?? call['contact_id'] as String? ?? 'Unknown'),
          subtitle: Text(direction == 'incoming' ? 'Incoming' : 'Outgoing'),
          trailing: const Icon(Icons.call, color: Colors.green),
          onTap: () {
            // Tap a history entry to redial the contact.
            final contactId = call['contact_id'] as String?;
            if (contactId != null && contactId.isNotEmpty) {
              context.go('/call/$contactId');
            }
          },
        );
      },
    );
  }
}
