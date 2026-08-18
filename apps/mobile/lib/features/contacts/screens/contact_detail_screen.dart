import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
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

  /// 编辑联系人：仅备注名 + 头像（手机号是身份，不可改）。
  Future<void> _showEditDialog(Contact contact) async {
    final nameController =
        TextEditingController(text: contact.displayName);
    String? avatarPath = contact.avatarPath; // 未更换则保留原头像。
    bool didSave = false;

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Edit Contact'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 头像选择（点击选图，无头像显示占位）。
              InkWell(
                onTap: () async {
                  final picked = await ImagePicker()
                      .pickImage(source: ImageSource.gallery);
                  if (picked == null) return;
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
                    : const CircleAvatar(
                        radius: 32, child: Icon(Icons.person, size: 32)),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  prefixIcon: Icon(Icons.person),
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
                if (name.isEmpty) return;
                try {
                  await DatabaseManager.instance.updateContactDetails(
                    contact.id,
                    displayName: name,
                    avatarPath: avatarPath,
                  );
                  didSave = true;
                  if (ctx.mounted) Navigator.pop(ctx, true);
                } catch (e) {
                  if (ctx.mounted) {
                    ScaffoldMessenger.of(ctx).showSnackBar(
                      SnackBar(content: Text('Failed: $e')),
                    );
                  }
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );

    if (result != true || !didSave) return;
    // 等对话框关闭动画完全结束后再刷新/dispose，避免触碰已销毁的 controller。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      nameController.dispose();
      if (mounted) _loadContact();
    });
  }

  /// 删除联系人（级联删除其通话记录与整个聊天），确认后返回列表。
  Future<void> _confirmDelete(Contact contact) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Contact'),
        content: const Text(
            'This will also delete the call history and the entire chat '
            'with this contact.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await DatabaseManager.instance.deleteContact(contact.id);
      if (mounted) context.pop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed: $e')),
        );
      }
    }
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
      appBar: AppBar(
        title: Text(contact.displayName),
        // 机器人是系统注入的（每次加载会话列表都会重建），不提供编辑/删除。
        actions: contact.id == 'bot-luozha'
            ? null
            : [
                IconButton(
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: () => _showEditDialog(contact),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _confirmDelete(contact),
                ),
              ],
      ),
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
