import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/storage/database.dart';
import '../../../shared/models/contact.dart';

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
    if (mounted) setState(() {
      _contacts = rows.map((r) => Contact.fromJson(r)).toList();
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Contacts'),
        actions: [IconButton(icon: const Icon(Icons.person_add), onPressed: () {})],
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
                      onTap: () => context.go('/contacts/${contact.id}'),
                    );
                  },
                ),
    );
  }
}
