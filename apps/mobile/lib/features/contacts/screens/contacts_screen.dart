import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/network/api_client.dart';
import '../../../core/storage/database.dart';
import '../../../shared/models/contact.dart';
import '../contact_manager.dart';

class ContactsScreen extends ConsumerStatefulWidget {
  const ContactsScreen({super.key});
  @override
  ConsumerState<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends ConsumerState<ContactsScreen> {
  List<Contact> _contacts = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadContacts();
  }

  Future<void> _loadContacts() async {
    final rows = await DatabaseManager.instance.getContacts();
    if (mounted) {
      setState(() {
        _contacts = rows.map((r) => Contact.fromJson(r)).toList();
        _loading = false;
      });
    }
  }

  Future<void> _showAddContactDialog(BuildContext context) async {
    final nameController = TextEditingController();
    final phoneController = TextEditingController();
    bool didAdd = false;

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add Contact'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: 'Name',
                prefixIcon: Icon(Icons.person),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: phoneController,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: 'Phone Number',
                prefixIcon: Icon(Icons.phone),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              final name = nameController.text.trim();
              final phone = phoneController.text.trim();
              if (name.isEmpty || phone.isEmpty) return;
              try {
                final mgr = ContactManager(ApiClient());
                await mgr.addContact(displayName: name, phoneNumber: phone);
                didAdd = true;
                if (ctx.mounted) Navigator.pop(ctx, true);
              } catch (e) {
                if (ctx.mounted) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    SnackBar(content: Text('Failed: $e')),
                  );
                }
              }
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );

    if (result != true || !didAdd) return;

    // Reload after the next frame so the dialog's InheritedElement tree
    // is fully deactivated before setState rebuilds the parent widget.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _reloadIfMounted();
      // Dispose controllers only after the dialog is fully closed to avoid
      // touching a disposed controller during the closing animation.
      nameController.dispose();
      phoneController.dispose();
    });
  }

  void _reloadIfMounted() {
    if (mounted) _loadContacts();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Contacts'),
        actions: [IconButton(icon: const Icon(Icons.person_add), onPressed: () => _showAddContactDialog(context))],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _contacts.isEmpty
              ? const Center(child: Text('No contacts yet'))
              : ListView.builder(
                  itemCount: _contacts.length,
                  itemBuilder: (context, index) {
                    final contact = _contacts[index];
                    return ListTile(
                      leading: CircleAvatar(child: Text(contact.initials)),
                      title: Text(contact.displayName),
                      subtitle: contact.isRegistered
                          ? const Text('MyPhone User', style: TextStyle(color: Colors.green))
                          : null,
                      trailing: contact.isRegistered
                          ? const Icon(Icons.call, color: Colors.green)
                          : const Icon(Icons.person_add, color: Colors.grey),
                      onTap: () => context.push('/contacts/${contact.id}'),
                    );
                  },
                ),
    );
  }
}
