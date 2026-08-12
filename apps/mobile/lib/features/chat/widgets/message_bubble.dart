/// 单条聊天气泡：入站靠左 / 出站靠右，配色 + 送达勾 + 可选时间戳。
library;

import 'package:flutter/material.dart';

class MessageBubble extends StatelessWidget {
  final String text;
  final String kind;
  final bool isOutgoing;
  final String? status;
  final int? timestamp;

  const MessageBubble({
    super.key,
    required this.text,
    required this.kind,
    required this.isOutgoing,
    this.status,
    this.timestamp,
  });

  /// 与 ChatSessionController._isPureEmoji 保持一致的纯 emoji 判定。
  static final RegExp _emojiPattern = RegExp(
    r'^[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}\u{FE0F}\u{200D}\u{1F1E6}-\u{1F1FF}]+$',
    unicode: true,
  );

  bool get _isPureEmoji =>
      kind == 'emoji' ||
      (text.trim().isNotEmpty && _emojiPattern.hasMatch(text.trim()));

  /// 附件/图片消息没有可展示文本时给一个占位（v0.5 附件暂为占位，正常不会出现）。
  String get _displayText {
    if (text.isNotEmpty) return text;
    switch (kind) {
      case 'image':
        return '[图片]';
      case 'video':
        return '[视频]';
      case 'file':
        return '[文件]';
      default:
        return '';
    }
  }

  String _formatTime(int ms) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(dt.year, dt.month, dt.day);
    final hhmm =
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    if (day == today) return hhmm;
    if (now.difference(day).inDays == 1) return '昨天 $hhmm';
    return '${dt.month.toString().padLeft(2, '0')}-'
        '${dt.day.toString().padLeft(2, '0')} $hhmm';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isEmoji = _isPureEmoji;
    final bubbleColor =
        isOutgoing ? scheme.primary : scheme.surfaceContainerHighest;
    final textColor = isOutgoing ? scheme.onPrimary : scheme.onSurface;

    return Align(
      alignment: isOutgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: Column(
        crossAxisAlignment:
            isOutgoing ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            margin: const EdgeInsets.symmetric(vertical: 3),
            padding: isEmoji
                ? const EdgeInsets.symmetric(horizontal: 12, vertical: 4)
                : const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.72,
            ),
            decoration: BoxDecoration(
              color: bubbleColor,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(16),
                topRight: const Radius.circular(16),
                bottomLeft: Radius.circular(isOutgoing ? 16 : 4),
                bottomRight: Radius.circular(isOutgoing ? 4 : 16),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isEmoji)
                  Text(_displayText,
                      style: const TextStyle(fontSize: 40, height: 1.1))
                else
                  Text(
                    _displayText,
                    style: TextStyle(
                      color: textColor,
                      fontSize: 15,
                      height: 1.35,
                    ),
                  ),
                if (isOutgoing && status != null) ...[
                  const SizedBox(height: 2),
                  _DeliveryTick(status: status!, textColor: textColor),
                ],
              ],
            ),
          ),
          if (timestamp != null)
            Padding(
              padding: const EdgeInsets.only(left: 12, right: 12, top: 1),
              child: Text(
                _formatTime(timestamp!),
                style: TextStyle(fontSize: 10, color: scheme.outline),
              ),
            ),
        ],
      ),
    );
  }
}

/// 送达状态小勾：✓ 已发送 / ✓✓ 已送达 / ✓✓(蓝) 已读 / ! 失败。
class _DeliveryTick extends StatelessWidget {
  final String status;
  final Color textColor;
  const _DeliveryTick({required this.status, required this.textColor});

  @override
  Widget build(BuildContext context) {
    switch (status) {
      case 'sent':
        return Text('✓',
            style: TextStyle(
                fontSize: 12, color: textColor.withOpacity(0.7)));
      case 'delivered':
        return Text('✓✓',
            style: TextStyle(
                fontSize: 12, color: textColor.withOpacity(0.7)));
      case 'read':
        return const Text('✓✓',
            style: TextStyle(fontSize: 12, color: Color(0xFF4FC3F7)));
      case 'failed':
        return const Icon(Icons.error_outline, size: 14, color: Colors.red);
      default:
        return const SizedBox.shrink();
    }
  }
}
