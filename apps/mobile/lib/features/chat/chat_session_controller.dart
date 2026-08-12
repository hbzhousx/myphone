/// 单个会话的收发编排：棘轮加解密、消息入库、阅后即焚、回执生成。
library;

import 'dart:convert';

import '../../core/crypto/chat_ratchet.dart';
import '../../core/crypto/chat_session_manager.dart';
import '../../core/network/chat_signal.dart';
import '../../core/network/signaling_client.dart';
import '../../core/storage/database.dart';

class ChatSessionController {
  final DatabaseManager _db;
  final ChatSessionManager _sessions;
  final SignalingClient _signaling;
  final String _localUserId;
  final String _remoteUserId;
  final String _conversationId;

  ChatSessionController({
    required DatabaseManager db,
    required ChatSessionManager sessions,
    required SignalingClient signaling,
    required String localUserId,
    required String remoteUserId,
    required String conversationId,
  })  : _db = db,
        _sessions = sessions,
        _signaling = signaling,
        _localUserId = localUserId,
        _remoteUserId = remoteUserId,
        _conversationId = conversationId;

  /// 发送文本/表情消息。
  Future<Map<String, dynamic>?> sendText(
    String body, {
    int expiresInSeconds = 0,
  }) async {
    var session = await _sessions.loadSession(_conversationId);
    if (session == null) {
      try {
        session = await _sessions.establishAsInitiator(
          remoteUserId: _remoteUserId,
          conversationId: _conversationId,
        );
      } catch (e) {
        return {'error': 'no session: $e'};
      }
    }

    final isEmoji = _isPureEmoji(body);
    final messageId = _newId();
    final plaintext =
        utf8.encode(jsonEncode({'kind': isEmoji ? 'emoji' : 'text', 'body': body}));

    final aad = ChatRatchet.associatedData(
      senderUserId: _localUserId,
      recipientUserId: _remoteUserId,
      conversationId: _conversationId,
    );
    final enc = await ChatRatchet.encrypt(session, plaintext, aad: aad);
    await _sessions.saveSession(_conversationId, enc.session);

    final payload = <String, dynamic>{
      'message_id': messageId,
      'ciphertext': base64Encode(enc.frame.toBytes()),
      'expires_in_seconds': expiresInSeconds,
    };
    final sig = ChatSignal(
      type: ChatSignalType.chatMessage,
      fromUserId: _localUserId,
      toUserId: _remoteUserId,
      messageId: messageId,
      payload: payload,
    );
    _signaling.sendChatSignal(sig);

    await _db.insertMessage({
      'id': messageId,
      'conversation_id': _conversationId,
      'direction': 'outgoing',
      'kind': isEmoji ? 'emoji' : 'text',
      'body': body,
      'status': 'sent',
      'expires_in_seconds': expiresInSeconds,
      'expires_at': expiresInSeconds > 0
          ? DateTime.now().millisecondsSinceEpoch + expiresInSeconds * 1000
          : null,
      'sent_at': DateTime.now().millisecondsSinceEpoch,
    });
    await _touchConversation(body, messageId);

    return {'message_id': messageId};
  }

  /// 处理入站 chatMessage（解密、入库、回执、阅后即焚）。
  Future<void> handleIncoming(ChatSignal signal) async {
    final payload = signal.payload ?? const {};
    final messageId =
        payload['message_id'] as String? ?? signal.messageId ?? _newId();

    // 已有记录（离线队列重投/回执重放）→ 忽略。
    if (await _db.getMessage(messageId) != null) return;

    final ciphertextB64 = payload['ciphertext'] as String?;
    if (ciphertextB64 == null) return;

    var session = await _sessions.loadSession(_conversationId);
    if (session == null) {
      try {
        session = await _sessions.establishAsResponder(
          remoteUserId: _remoteUserId,
          conversationId: _conversationId,
          initPayload:
              (payload['init_payload'] as Map<String, dynamic>?) ?? const {},
        );
      } catch (e) {
        // 无法建立会话（身份变更等）——丢弃并标记 failed。
        await _db.insertMessage({
          'id': messageId,
          'conversation_id': _conversationId,
          'direction': 'incoming',
          'kind': 'text',
          'body': null,
          'status': 'failed',
          'created_at': DateTime.now().millisecondsSinceEpoch,
        });
        return;
      }
    }

    final aad = ChatRatchet.associatedData(
      senderUserId: _remoteUserId,
      recipientUserId: _localUserId,
      conversationId: _conversationId,
    );
    final ChatRatchetDecryptResult dec;
    try {
      dec = await ChatRatchet.decrypt(
        session,
        ChatEncryptedFrame.fromBytes(base64Decode(ciphertextB64)),
        aad: aad,
      );
    } catch (e) {
      // 解密失败（篡改/重放）——记录 failed，不回卷链。
      await _db.insertMessage({
        'id': messageId,
        'conversation_id': _conversationId,
        'direction': 'incoming',
        'kind': 'text',
        'body': null,
        'status': 'failed',
        'created_at': DateTime.now().millisecondsSinceEpoch,
      });
      return;
    }
    await _sessions.saveSession(_conversationId, dec.session);

    final parsed = jsonDecode(utf8.decode(dec.plaintext)) as Map<String, dynamic>;
    final kind = parsed['kind'] as String? ?? 'text';
    final body = parsed['body'] as String? ?? '';
    final expiresIn = (payload['expires_in_seconds'] as num?)?.toInt() ?? 0;

    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.insertMessage({
      'id': messageId,
      'conversation_id': _conversationId,
      'direction': 'incoming',
      'kind': kind,
      'body': body,
      'status': 'delivered',
      'expires_in_seconds': expiresIn,
      'expires_at': expiresIn > 0 ? now + expiresIn * 1000 : null,
      'received_at': now,
      'created_at': now,
    });
    await _touchConversation(body, messageId);

    // 回执：delivered（已读回执由 UI 显式触发 markRead）。
    _sendReceipt(messageId, 'delivered');
  }

  /// 标记已读：更新本地 + 发送 read 回执。
  Future<void> markRead(String messageId) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.updateMessageStatus(messageId, 'read', readAt: now);
    _sendReceipt(messageId, 'read');
  }

  /// 处理入站回执。
  Future<void> handleReceipt(ChatSignal signal) async {
    final payload = signal.payload ?? const {};
    final messageId = payload['message_id'] as String?;
    final kind = payload['kind'] as String?;
    if (messageId == null) return;
    final msg = await _db.getMessage(messageId);
    if (msg == null) return;
    if (kind == 'delivered' && msg['status'] == 'sent') {
      await _db.updateMessageStatus(messageId, 'delivered',
          deliveredAt: DateTime.now().millisecondsSinceEpoch);
    } else if (kind == 'read') {
      await _db.updateMessageStatus(messageId, 'read',
          readAt: DateTime.now().millisecondsSinceEpoch);
    }
  }

  /// 处理入站阅后即焚设置变更。
  Future<void> handleDisappearing(ChatSignal signal) async {
    final payload = signal.payload ?? const {};
    final seconds = (payload['expires_in_seconds'] as num?)?.toInt() ?? 0;
    await _db.upsertConversation({
      'id': _conversationId,
      'remote_user_id': _remoteUserId,
      'disappearing_seconds': seconds,
    });
  }

  /// 发送阅后即焚设置变更（会话默认）。
  void sendDisappearingSetting(int seconds) {
    _signaling.sendChatSignal(ChatSignal(
      type: ChatSignalType.chatDisappearing,
      fromUserId: _localUserId,
      toUserId: _remoteUserId,
      payload: {'expires_in_seconds': seconds},
    ));
  }

  void _sendReceipt(String messageId, String kind) {
    _signaling.sendChatSignal(ChatSignal(
      type: ChatSignalType.chatReceipt,
      fromUserId: _localUserId,
      toUserId: _remoteUserId,
      messageId: messageId,
      payload: {'message_id': messageId, 'kind': kind},
    ));
  }

  Future<void> _touchConversation(String preview, String lastMessageId) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.upsertConversation({
      'id': _conversationId,
      'remote_user_id': _remoteUserId,
      'last_message_at': now,
      'last_message_preview':
          preview.length > 60 ? preview.substring(0, 60) : preview,
    });
  }

  bool _isPureEmoji(String s) {
    final trimmed = s.trim();
    if (trimmed.isEmpty) return false;
    final emojiPattern = RegExp(
      r'^[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}\u{FE0F}\u{200D}\u{1F1E6}-\u{1F1FF}]+$',
      unicode: true,
    );
    return emojiPattern.hasMatch(trimmed);
  }

  String _newId() {
    final rnd = DateTime.now().microsecondsSinceEpoch;
    return 'msg-$rnd-${DateTime.now().millisecondsSinceEpoch % 100000}';
  }
}
