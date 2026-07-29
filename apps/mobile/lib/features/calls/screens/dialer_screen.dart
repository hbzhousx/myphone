import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/storage/database.dart';

class DialerScreen extends ConsumerWidget {
  const DialerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('MyPhone')),
      body: Column(
        children: [
          Expanded(child: _RecentCallsList()),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _ActionButton(icon: Icons.contacts, label: 'Contacts', onTap: () => context.go('/contacts')),
                  _ActionButton(icon: Icons.dialpad, label: 'Keypad', onTap: () {}),
                  _ActionButton(icon: Icons.history, label: 'Recent', onTap: () {}),
                  _ActionButton(icon: Icons.settings, label: 'Settings', onTap: () {}),
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
  @override
  State<_RecentCallsList> createState() => _RecentCallsListState();
}

class _RecentCallsListState extends State<_RecentCallsList> {
  List<Map<String, dynamic>> _calls = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadCalls();
  }

  Future<void> _loadCalls() async {
    final calls = await DatabaseManager.instance.getCallHistory();
    if (mounted) setState(() { _calls = calls; _loading = false; });
  }

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
          title: Text(call['contact_id'] as String? ?? 'Unknown'),
          subtitle: Text(direction == 'incoming' ? 'Incoming' : 'Outgoing'),
          trailing: const Icon(Icons.call, color: Colors.green),
          onTap: () {},
        );
      },
    );
  }
}
