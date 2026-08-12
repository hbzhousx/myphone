import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/storage/database.dart';
import '../../../shared/models/contact.dart';

class ContactDetailScreen extends ConsumerStatefulWidget {
  final String contactId;
  const ContactDetailScreen({super.key, required this.contactId});
  @override
  ConsumerState<ContactDetailScreen> createState() =>
      _ContactDetailScreenState();
}

class _ContactDetailScreenState extends ConsumerState<ContactDetailScreen> {
  Contact? _contact;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadContact();
  }

  Future<void> _loadContact() async {
    final row = await DatabaseManager.instance.getContact(widget.contactId);
    if (mounted) {
      setState(() {
        _contact = row != null ? Contact.fromJson(row) : null;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_loading) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (_contact == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('Contact not found')),
      );
    }
    final contact = _contact!;

    return Scaffold(
      appBar: AppBar(title: Text(contact.displayName)),
      body: Column(
        children: [
          const SizedBox(height: 32),
          CircleAvatar(
              radius: 48,
              child:
                  Text(contact.initials, style: const TextStyle(fontSize: 32))),
          const SizedBox(height: 16),
          Text(contact.displayName, style: theme.textTheme.headlineSmall),
          if (contact.isRegistered)
            Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('MyPhone User',
                    style: TextStyle(
                        color: theme.colorScheme.primary, fontSize: 14))),
          const SizedBox(height: 32),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 48),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _ActionButton(
                    icon: Icons.call,
                    label: 'Audio Call',
                    onTap: () => context.go('/call/${contact.id}')),
                _ActionButton(
                    icon: Icons.message,
                    label: 'Message',
                    onTap: () => context.push('/chat/${contact.id}')),
              ],
            ),
          ),
          const Spacer(),
          if (contact.publicKeyFingerprint != null)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      Row(children: [
                        Icon(Icons.fingerprint,
                            color: theme.colorScheme.primary),
                        const SizedBox(width: 8),
                        const Text('Contact Key Fingerprint',
                            style: TextStyle(fontWeight: FontWeight.w600))
                      ]),
                      const SizedBox(height: 8),
                      Text(contact.publicKeyFingerprint!,
                          style: const TextStyle(
                              fontSize: 12, fontFamily: 'monospace')),
                    ],
                  ),
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
  const _ActionButton(
      {required this.icon, required this.label, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        CircleAvatar(
            radius: 28,
            backgroundColor: Theme.of(context).colorScheme.primaryContainer,
            child: IconButton(icon: Icon(icon), onPressed: onTap)),
        const SizedBox(height: 4),
        Text(label, style: const TextStyle(fontSize: 12)),
      ],
    );
  }
}
