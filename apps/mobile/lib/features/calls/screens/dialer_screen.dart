import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/network/service_bridge.dart';
import '../../../core/storage/database.dart';
import '../../../shared/utils/time_format.dart';
import '../../contacts/contact_manager.dart';
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
    // All login paths land on /dialer — warm contact presence in the
    // background so the contacts list shows fresh statuses on first open.
    unawaited(ref.read(contactPresenceProvider.notifier).refresh());
    // v0.4: 拉起常驻前台服务（独占 WS 保持登录 + 来电唤醒）。幂等。
    unawaited(ResidentService.ensureStarted());
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
    ref.watch(callStateProvider);
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
                  _ActionButton(icon: Icons.message, label: 'Messages', onTap: () => context.push('/conversations')),
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

  Future<void> _deleteCall(Map<String, dynamic> call) async {
    final id = call['id'] as String?;
    if (id == null) return;
    await DatabaseManager.instance.deleteCallHistory(id);
    setState(() => _calls.removeWhere((c) => c['id'] == id));
  }

  Future<void> _clearAll() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear call history'),
        content: const Text('Delete all call records?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Clear')),
        ],
      ),
    );
    if (confirm == true && mounted) {
      await DatabaseManager.instance.clearCallHistory();
      setState(() => _calls = []);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    return Column(
      children: [
        if (_calls.isNotEmpty)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: _clearAll,
              icon: const Icon(Icons.delete_sweep, size: 18),
              label: const Text('Clear'),
            ),
          ),
        Expanded(
          child: _calls.isEmpty
              ? const Center(
                  child: Text('No recent calls',
                      style: TextStyle(color: Colors.grey)))
              : ListView.builder(
                  itemCount: _calls.length,
                  itemBuilder: (context, index) {
                    final call = _calls[index];
                    final direction = call['direction'] as String;
                    final isMissed = call['status'] == 'missed';
                    return Dismissible(
                      key: ValueKey(call['id']),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        color: Colors.red,
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 20),
                        child: const Icon(Icons.delete, color: Colors.white),
                      ),
                      onDismissed: (_) => _deleteCall(call),
                      child: ListTile(
                        leading: Icon(
                          direction == 'incoming'
                              ? Icons.call_received
                              : Icons.call_made,
                          color: isMissed ? Colors.red : Colors.green,
                        ),
                        title: Text(call['contact_name'] as String? ??
                            call['contact_id'] as String? ??
                            'Unknown'),
                        subtitle: Text(
                          '${direction == 'incoming' ? '来电' : '去电'} · '
                          '${formatCallTime((call['started_at'] as num?)?.toInt() ?? 0)}',
                        ),
                        trailing: const Icon(Icons.call, color: Colors.green),
                        onTap: () {
                          // Tap a history entry to redial the contact.
                          final contactId = call['contact_id'] as String?;
                          if (contactId != null && contactId.isNotEmpty) {
                            context.go('/call/$contactId');
                          }
                        },
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
