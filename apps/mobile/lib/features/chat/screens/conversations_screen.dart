/// 会话列表页：展示最近会话（头像/名称/预览/时间/未读角标）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/storage/database.dart';
import '../../../shared/widgets/contact_avatar.dart';
import '../chat_state.dart';

class ConversationsScreen extends ConsumerStatefulWidget {
  const ConversationsScreen({super.key});
  @override
  ConsumerState<ConversationsScreen> createState() =>
      _ConversationsScreenState();
}

class _ConversationsScreenState extends ConsumerState<ConversationsScreen> {
  List<Map<String, dynamic>> _conversations = [];
  bool _loading = true;
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    // 保持聊天状态存活（信令订阅 / 会话控制器）。
    ref.read(chatStateProvider);
    _loadConversations();
    // 轮询刷新，捕捉后台到达的新消息/未读变化。
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      _loadConversations();
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadConversations() async {
    try {
      // ★注入机器人罗吒助手会话（常驻会话列表，文件助手式）。
      await DatabaseManager.instance.upsertConversation({
        'id': 'conv-bot-luozha',
        'remote_user_id': 'bot-luozha',
        'remote_display_name': '罗吒',
      });
      // 机器人作为联系人（供发起聊天选择）。
      final bot = await DatabaseManager.instance
          .getContact('bot-luozha');
      if (bot == null) {
        await DatabaseManager.instance.upsertContact({
          'id': 'bot-luozha',
          'display_name': '罗吒',
          'phone_hash': 'bot:luozha',
          'is_registered': 0,
        });
      }
      var rows = await DatabaseManager.instance.getConversations();
      rows = await _enrichDisplayNames(rows);
      if (!mounted) return;
      setState(() {
        _conversations = rows;
        _loading = false;
      });
    } catch (e) {
      debugPrint('[CONVERSATIONS] load failed: $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 会话表里可能没有 display_name（首次由对端发消息建会话），用联系人表补齐。
  Future<List<Map<String, dynamic>>> _enrichDisplayNames(
    List<Map<String, dynamic>> rows,
  ) async {
    final out = <Map<String, dynamic>>[];
    for (final conv in rows) {
      var name = conv['remote_display_name'] as String?;
      String? avatarPath = conv['_avatar_path'] as String?;
      final remoteId = conv['remote_user_id'] as String?;
      if (remoteId != null) {
        try {
          final contact = await DatabaseManager.instance.getContact(remoteId);
          if (contact != null) {
            if (name == null || name.isEmpty) {
              name = contact['display_name'] as String?;
            }
            avatarPath ??= contact['avatar_path'] as String?;
          }
        } catch (_) {}
      }
      name ??= remoteId ?? '';
      out.add({...conv, '_display_name': name, '_avatar_path': avatarPath});
    }
    return out;
  }

  String _initialsOf(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return '?';
    return trimmed
        .split(RegExp(r'\s+'))
        .take(2)
        .map((w) => w.isNotEmpty ? w[0].toUpperCase() : '')
        .join();
  }

  /// 发起新聊天：弹联系人选择，选中后进入聊天页（会话懒创建）。
  Future<void> _startNewChat() async {
    if (!mounted) return;
    final contacts = await _loadContacts();
    if (!mounted) return;

    if (contacts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('暂无联系人，请先到通讯录添加')),
      );
      return;
    }

    final selected = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('选择联系人', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: contacts.length,
                itemBuilder: (ctx, i) {
                  final c = contacts[i];
                  final name = (c['display_name'] as String?) ?? '';
                  return ListTile(
                    leading: ContactAvatar(
                      avatarPath: c['avatar_path'] as String?,
                      initials: _initialsOf(name),
                    ),
                    title: Text(name,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    onTap: () => Navigator.pop(ctx, c),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );

    if (selected != null && mounted) {
      final contactId = selected['id'] as String;
      // 预建会话（remote_user_id = 联系人 id），确保消息页有会话。
      await DatabaseManager.instance.upsertConversation({
        'id': 'conv-$contactId',
        'remote_user_id': contactId,
        'remote_display_name': (selected['display_name'] as String?) ?? '',
      });
      if (mounted) context.push('/chat/$contactId');
    }
  }

  Future<List<Map<String, dynamic>>> _loadContacts() async {
    try {
      return await DatabaseManager.instance.getContacts();
    } catch (_) {
      return [];
    }
  }

  String _relativeTime(int? ms) {
    if (ms == null) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes}分钟前';
    if (diff.inHours < 24) return '${diff.inHours}小时前';
    if (diff.inDays < 7) return '${diff.inDays}天前';
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-'
        '${dt.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    // Watch 以保持聊天状态（信令/控制器）存活。
    ref.watch(chatStateProvider);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('消息')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _startNewChat,
        icon: const Icon(Icons.chat_bubble_outline),
        label: const Text('发起聊天'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _conversations.isEmpty
              ? const Center(child: Text('暂无会话'))
              : ListView.builder(
                  itemCount: _conversations.length,
                  itemBuilder: (context, index) {
                    final conv = _conversations[index];
                    final name = conv['_display_name'] as String? ?? '';
                    final preview =
                        conv['last_message_preview'] as String? ?? '';
                    final unread = (conv['unread_count'] as num?)?.toInt() ?? 0;
                    final lastAt =
                        (conv['last_message_at'] as num?)?.toInt();
                    final remoteId = conv['remote_user_id'] as String? ?? '';

                    return ListTile(
                      leading: ContactAvatar(
                        avatarPath: conv['_avatar_path'] as String?,
                        initials: _initialsOf(name),
                      ),
                      title: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        preview,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            _relativeTime(lastAt),
                            style: TextStyle(
                                fontSize: 12, color: scheme.outline),
                          ),
                          const SizedBox(height: 4),
                          if (unread > 0)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              constraints: const BoxConstraints(minWidth: 20),
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: scheme.primary,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                unread > 99 ? '99+' : '$unread',
                                style: TextStyle(
                                    fontSize: 11, color: scheme.onPrimary),
                              ),
                            ),
                        ],
                      ),
                      onTap: () => context.push('/chat/$remoteId'),
                    );
                  },
                ),
    );
  }
}
