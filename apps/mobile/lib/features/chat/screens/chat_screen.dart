/// 单会话聊天页：消息列表 + 输入栏（emoji/附件/文本）+ 阅后即焚选择。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/storage/database.dart';
import '../chat_state.dart';
import '../widgets/message_bubble.dart';

/// 阅后即焚可选项：秒数 → 显示文案。
const List<(int, String)> _disappearOptions = [
  (0, '关'),
  (5, '5秒'),
  (30, '30秒'),
  (60, '1分钟'),
  (3600, '1小时'),
  (86400, '24小时'),
  (604800, '1周'),
];

class ChatScreen extends ConsumerStatefulWidget {
  final String contactId;
  const ChatScreen({super.key, required this.contactId});
  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _inputController = TextEditingController();
  List<Map<String, dynamic>> _messages = [];
  bool _loading = true;
  String _displayName = '';
  int _disappearSeconds = 0;
  Timer? _pollTimer;

  String get _conversationId => 'conv-${widget.contactId}';

  @override
  void initState() {
    super.initState();
    ref.read(chatStateProvider.notifier).setActiveConversation(_conversationId);
    _loadContact();
    _loadMessages();
    // 周期轮询：捕捉入站新消息/回执/阅后即焚（信令落库后在此刷新）。
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _loadMessages();
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _inputController.dispose();
    ref.read(chatStateProvider.notifier).setActiveConversation(null);
    super.dispose();
  }

  /// 联系人 id → 展示名（联系人表匹配失败则回退为原始 id）。
  Future<void> _loadContact() async {
    String name = widget.contactId;
    try {
      final row = await DatabaseManager.instance.getContact(widget.contactId);
      if (row != null) {
        final n = row['display_name'] as String?;
        if (n != null && n.isNotEmpty) name = n;
      }
    } catch (_) {}
    if (mounted) setState(() => _displayName = name);
  }

  Future<void> _loadMessages() async {
    try {
      final rows = await DatabaseManager.instance
          .getMessages(_conversationId, limit: 200);
      if (!mounted) return;
      setState(() {
        _messages = rows;
        _loading = false;
      });
      _maybeReadIncoming(rows);
      _syncDisappearSetting();
    } catch (e) {
      debugPrint('[CHAT] load messages failed: $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 新入站消息显示时自动回已读（markRead 会发 read 回执给对端）。
  Future<void> _maybeReadIncoming(List<Map<String, dynamic>> rows) async {
    final controller = ref.read(chatStateProvider.notifier).controllerFor(
          remoteUserId: widget.contactId,
          conversationId: _conversationId,
        );
    for (final msg in rows) {
      final direction = msg['direction'] as String?;
      final status = msg['status'] as String?;
      if (direction == 'incoming' && status != null && status != 'read') {
        await controller.markRead(msg['id'] as String);
      }
    }
  }

  /// 把会话当前的阅后即焚设置同步到 AppBar 选择器。
  Future<void> _syncDisappearSetting() async {
    try {
      final conv = await DatabaseManager.instance
          .getConversation(_conversationId);
      final seconds = (conv?['disappearing_seconds'] as num?)?.toInt() ?? 0;
      if (seconds != _disappearSeconds && mounted) {
        setState(() => _disappearSeconds = seconds);
      }
    } catch (_) {}
  }

  Future<void> _sendText() async {
    final body = _inputController.text.trim();
    if (body.isEmpty) return;
    _inputController.clear();
    final result = await ref.read(chatStateProvider.notifier).controllerFor(
          remoteUserId: widget.contactId,
          conversationId: _conversationId,
        ).sendText(body, expiresInSeconds: _disappearSeconds);
    if (result != null && result.containsKey('error')) {
      // 会话建立失败（未登录/离线）时给出提示，避免静默丢消息。
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('发送失败：${result['error']}')),
        );
      }
    }
    await _loadMessages();
  }

  /// 常用 emoji 快速选择（v0.5 简化：不引入 emoji_picker 依赖）。
  static const List<String> _quickEmojis = [
    '😀', '😂', '😍', '😎', '😭', '😡', '👍', '👎',
    '🙏', '👏', '💪', '🎉', '❤️', '💔', '🔥', '✅',
    '❌', '❓', '❗', '💤', '☕', '🍺', '🌹', '⭐',
  ];

  Future<void> _insertEmoji() async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final e in _quickEmojis)
                InkWell(
                  onTap: () => Navigator.pop(ctx, e),
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Text(e, style: const TextStyle(fontSize: 26)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (selected != null && mounted) {
      _inputController.text += selected;
    }
  }

  Future<void> _pickAndSendFile() async {
    // v0.5 简化：文件/图片传输暂以占位提示，不接数据通道完整流程。
    // 数据链路（ChatFileTransferManager）已就绪，后续可在此接入。
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('文件传输即将上线')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(_displayName.isEmpty ? widget.contactId : _displayName),
        actions: [
          // 阅后即焚设置：变更后发信令给对端同步会话默认值。
          PopupMenuButton<int>(
            initialValue: _disappearSeconds,
            onSelected: (seconds) {
              setState(() => _disappearSeconds = seconds);
              ref
                  .read(chatStateProvider.notifier)
                  .controllerFor(
                    remoteUserId: widget.contactId,
                    conversationId: _conversationId,
                  )
                  .sendDisappearingSetting(seconds);
            },
            itemBuilder: (context) => [
              for (final (seconds, label) in _disappearOptions)
                PopupMenuItem<int>(value: seconds, child: Text(label)),
            ],
            icon: const Icon(Icons.timer_outlined),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _messages.isEmpty
                    ? const Center(child: Text('暂无消息，发送一条开启端到端加密聊天'))
                    : ListView.builder(
                        reverse: true,
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: _messages.length,
                        itemBuilder: (context, index) {
                          final msg = _messages[_messages.length - 1 - index];
                          final outgoing =
                              msg['direction'] == 'outgoing';
                          return MessageBubble(
                            text: msg['body'] as String? ?? '',
                            kind: msg['kind'] as String? ?? 'text',
                            isOutgoing: outgoing,
                            status: msg['status'] as String?,
                            timestamp: (msg['created_at'] as num?)?.toInt(),
                          );
                        },
                      ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  IconButton(
                    icon: const Icon(Icons.emoji_emotions_outlined),
                    onPressed: _insertEmoji,
                  ),
                  Expanded(
                    child: TextField(
                      controller: _inputController,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.newline,
                      decoration: InputDecoration(
                        hintText: '输入消息…',
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 10),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                        ),
                      ),
                      onSubmitted: (_) => _sendText(),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.attach_file),
                    onPressed: _pickAndSendFile,
                  ),
                  IconButton(
                    icon: Icon(Icons.send, color: scheme.primary),
                    onPressed: _sendText,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
