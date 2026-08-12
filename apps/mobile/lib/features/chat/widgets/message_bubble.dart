/// 单条聊天气泡：入站靠左 / 出站靠右，配色 + 送达勾 + 可选时间戳。
/// 图片/文件消息展示缩略图/卡片，点击回调 [onAttachmentTap]。
library;

import 'dart:io';

import 'package:flutter/material.dart';

class MessageBubble extends StatelessWidget {
  final String text;
  final String kind;
  final bool isOutgoing;
  final String? status;
  final int? timestamp;

  /// 附件消息的 transfer_id（用于取本地路径/预览）。
  final String? transferId;

  /// 本地附件明文路径（图片/文件展示用，由 UI 层从 message_attachments 查出）。
  final String? attachmentPath;

  /// 附件点击回调（图片/文件预览）。
  final VoidCallback? onAttachmentTap;

  const MessageBubble({
    super.key,
    required this.text,
    required this.kind,
    required this.isOutgoing,
    this.status,
    this.timestamp,
    this.transferId,
    this.attachmentPath,
    this.onAttachmentTap,
  });

  bool get _isAttachment =>
      kind == 'image' || kind == 'video' || kind == 'file';

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

  /// 附件内容（图片缩略图 / 文件卡片）。点击触发 [onAttachmentTap]。
  Widget _buildAttachmentContent(ColorScheme scheme, Color textColor) {
    final path = attachmentPath;
    final canPreview = path != null && File(path).existsSync();

    Widget content;
    if (kind == 'image' && canPreview) {
      content = ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.file(
          File(path),
          width: 180,
          height: 180,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _fileCard(scheme),
        ),
      );
    } else if (kind == 'video' && canPreview) {
      content = Stack(
        alignment: Alignment.center,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.file(
              File(path),
              width: 180,
              height: 180,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => _fileCard(scheme),
            ),
          ),
          const Icon(Icons.play_circle_fill, size: 48, color: Colors.white70),
        ],
      );
    } else {
      content = _fileCard(scheme);
    }

    return GestureDetector(
      onTap: onAttachmentTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          content,
          const SizedBox(height: 2),
          Text(
            _displayText,
            style: TextStyle(color: textColor, fontSize: 12),
            overflow: TextOverflow.ellipsis,
          ),
          if (isOutgoing && status != null) ...[
            const SizedBox(height: 2),
            _DeliveryTick(status: status!, textColor: textColor),
          ],
        ],
      ),
    );
  }

  /// 文件/无法预览时的卡片。
  Widget _fileCard(ColorScheme scheme) {
    return Container(
      width: 180,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withOpacity(0.4),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            kind == 'file' ? Icons.insert_drive_file_outlined : Icons.image_outlined,
            color: scheme.primary,
            size: 28,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              _displayText,
              style: const TextStyle(fontSize: 13),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
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
            child: _isAttachment
                ? _buildAttachmentContent(scheme, textColor)
                : Column(
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
