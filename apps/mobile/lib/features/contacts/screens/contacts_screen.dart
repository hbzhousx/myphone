import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import '../../../core/network/api_client.dart';
import '../../../core/storage/database.dart';
import '../../../shared/models/contact.dart';
import '../../../shared/widgets/contact_avatar.dart';
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
    // Refresh online/offline presence in the background after loading.
    unawaited(ref.read(contactPresenceProvider.notifier).refresh());
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
    String? avatarPath; // 选中的头像（复制到 avatars/ 后的路径）。
    bool didAdd = false;

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Add Contact'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 头像选择（点击选图，无头像显示占位）。
              InkWell(
                onTap: () async {
                  final picked = await ImagePicker()
                      .pickImage(source: ImageSource.gallery);
                  if (picked == null) return;
                  // 复制到 app 私有目录 avatars/，避免原图被系统清理。
                  final dir = await getApplicationDocumentsDirectory();
                  final avatarsDir = '${dir.path}/avatars';
                  await Directory(avatarsDir).create(recursive: true);
                  final dest =
                      '$avatarsDir/${DateTime.now().millisecondsSinceEpoch}.jpg';
                  await File(picked.path).copy(dest);
                  if (ctx.mounted) {
                    setDialogState(() => avatarPath = dest);
                  }
                },
                child: avatarPath != null
                    ? CircleAvatar(
                        radius: 32,
                        backgroundImage: FileImage(File(avatarPath!)),
                      )
                    : CircleAvatar(
                        radius: 32,
                        child: const Icon(Icons.person, size: 32),
                      ),
              ),
            const SizedBox(height: 12),
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
                await mgr.addContact(
                  displayName: name,
                  phoneNumber: phone,
                  avatarPath: avatarPath,
                );
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
              : Consumer(builder: (context, ref, _) {
                  final presence = ref.watch(contactPresenceProvider);
                  return ListView.builder(
                    itemCount: _contacts.length,
                    itemBuilder: (context, index) {
                      final contact = _contacts[index];
                      final isOnline = presence[contact.id] ?? false;
                      return ListTile(
                        leading: ContactAvatar(
                          avatarPath: contact.avatarPath,
                          initials: contact.initials,
                        ),
                        title: Text(contact.displayName),
                        subtitle: contact.isRegistered
                            ? Text(
                                isOnline ? 'Online' : 'Offline',
                                style: TextStyle(
                                  color: isOnline ? Colors.green : Colors.grey,
                                  fontSize: 12,
                                ),
                              )
                            : null,
                        trailing: contact.isRegistered
                            ? const Icon(Icons.call, color: Colors.green)
                            : const Icon(Icons.person_add, color: Colors.grey),
                        onTap: () async {
                          await context.push('/contacts/${contact.id}');
                          // 详情页可能删除/编辑了联系人，返回后刷新。
                          if (mounted) _loadContacts();
                        },
                      );
                    },
                  );
                }),
    );
  }
}
