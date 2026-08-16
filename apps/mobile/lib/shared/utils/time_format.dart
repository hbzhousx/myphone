/// 时间格式化工具（跨特性共享）。
library;

/// 通话历史/列表时间：当天显示 `HH:mm`，昨天显示 `昨天`，更早显示 `M月d日`。
/// 与 message_bubble 的 _formatTime 同逻辑，但更早日期不带时间（对齐微信通话记录）。
String formatCallTime(int ms) {
  final dt = DateTime.fromMillisecondsSinceEpoch(ms);
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(dt.year, dt.month, dt.day);
  final hhmm =
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  if (day == today) return hhmm;
  if (now.difference(day).inDays == 1) return '昨天';
  return '${dt.month}月${dt.day}日';
}

/// 聊天消息时间：当天 `HH:mm`，昨天 `昨天 HH:mm`，更早 `MM-dd HH:mm`。
String formatMessageTime(int ms) {
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
