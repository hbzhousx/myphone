/// 会话消息的数据访问层：查询消息 + 补附件路径。
///
/// 把原本塞在 chat_screen 的 `_loadMessages` 里的数据逻辑抽到这里，
/// widget 只负责编排（轮询触发 + setState）。纯类、无状态管理依赖。
library;

import 'dart:io';

import '../../core/storage/database.dart';

/// 单个会话的消息仓库。
class ChatMessageRepository {
  final DatabaseManager _db;
  final String _conversationId;

  /// 诊断上报（fire-and-forget）。null = 关闭（kChatDiag 开关翻转时）。
  final void Function(String step, Map<String, dynamic> data)? onDiag;

  /// 附件路径缓存：local_plain_path 插入后不变（后续只改 status），
  /// 按 transfer_id 缓存即可消掉每轮轮询的 N+1 附件查询。
  final Map<String, Future<String?>> _attachmentPathCache = {};

  ChatMessageRepository({
    required DatabaseManager db,
    required String conversationId,
    this.onDiag,
  })  : _db = db,
        _conversationId = conversationId;

  /// 查询最新的 [limit] 条消息并为附件消息补 `_attachment_path`，
  /// 返回 UI 可直接渲染的列表（按时间正序）。
  Future<List<Map<String, dynamic>>> load({int limit = 200}) async {
    final rows = await _db.getMessages(_conversationId, limit: limit);
    onDiag?.call('ui:fetch', {'rows': rows.length});
    final enriched = <Map<String, dynamic>>[];
    for (final row in rows) {
      // ★必须拷贝为可写 map：sqflite 返回的 QueryRow 是只读的，
      //   直接 `msg['_attachment_path'] = ...` 会抛
      //   `Unsupported operation: read-only` → 中断循环 → setState 不执行 → 白屏。
      final msg = Map<String, dynamic>.from(row);
      // ★transfer_id 类型安全：DB 里可能是 int/其他，直接 as String? 会抛
      //   _TypeError 中断整个循环 → setState 不执行 → 白屏。安全转换。
      final tid = msg['transfer_id'];
      if (tid is String) {
        msg['_attachment_path'] = await _attachmentPath(tid);
      }
      enriched.add(msg);
    }
    return enriched;
  }

  Future<String?> _attachmentPath(String tid) =>
      _attachmentPathCache.putIfAbsent(tid, () async {
        final attach = await _db.getAttachment(tid);
        final p = attach?['local_plain_path'] as String?;
        if (p != null) {
          // 诊断：附件首次查到本地明文路径（缓存命中后不再上报，避免每轮刷）。
          onDiag?.call('ui:attach', {
            'tid': tid,
            'path': p,
            'exists': File(p).existsSync(),
          });
        }
        return p;
      });
}
