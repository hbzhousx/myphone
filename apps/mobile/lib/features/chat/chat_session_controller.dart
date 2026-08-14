/// 单个会话的收发编排：棘轮加解密、消息入库、阅后即焚、回执生成。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path_provider/path_provider.dart';

import '../../core/crypto/chat_crypto.dart';
import '../../core/crypto/chat_session_manager.dart';
import '../../core/crypto/crypto_manager.dart';
import '../../core/network/chat_signal.dart';
import '../../core/network/signaling_client.dart';
import '../../core/storage/database.dart';
import 'chat_file_transfer_manager.dart';

class ChatSessionController {
  final DatabaseManager _db;
  final ChatSessionManager _sessions;
  final SignalingClient _signaling;
  final String _localUserId;
  final String _remoteUserId;
  final String _conversationId;

  ChatFileTransferManager? _fileManager;

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

  /// 懒建数据通道文件传输管理器（每个会话一个）。
  ChatFileTransferManager get fileManager => _fileManager ??= ChatFileTransferManager(
        onSignal: (type, payload) {
          _signaling.sendChatSignal(ChatSignal(
            type: ChatSignalType.values.firstWhere((e) => e.name == type),
            fromUserId: _localUserId,
            toUserId: _remoteUserId,
            payload: {...payload, 'conversation_id': _conversationId},
          ));
        },
        onProgress: _onFileProgress,
      );

  /// 发送文本/表情消息。
  Future<Map<String, dynamic>?> sendText(
    String body, {
    int expiresInSeconds = 0,
  }) async {
    await _ensureConversation();
    var session = await _sessions.loadSession(_conversationId);
    Map<String, dynamic>? initPayload;
    if (session == null) {
      try {
        initPayload = await _sessions.establishAsInitiator(
          remoteUserId: _remoteUserId,
          conversationId: _conversationId,
        );
        // 建立会话后重新加载（establishAsInitiator 持久化了新会话）。
        session = await _sessions.loadSession(_conversationId);
      } catch (e) {
        return {'error': 'no session: $e'};
      }
    }

    final isEmoji = _isPureEmoji(body);
    final messageId = _newId();
    final plaintext =
        utf8.encode(jsonEncode({'kind': isEmoji ? 'emoji' : 'text', 'body': body}));
    if (session == null) return {'error': 'session unavailable'};

    final aad = ChatCrypto.associatedData(
      senderUserId: _localUserId,
      recipientUserId: _remoteUserId,
      conversationId: _conversationId,
    );
    final enc = await ChatCrypto.encryptMessage(
      session,
      plaintext,
      messageId: messageId,
      aad: aad,
    );
    await _sessions.saveSession(_conversationId, enc.session);

    final payload = <String, dynamic>{
      'message_id': messageId,
      'ciphertext': base64Encode(enc.ciphertext),
      'counter': enc.counter,
      'expires_in_seconds': expiresInSeconds,
      if (initPayload != null) 'init_payload': initPayload,
    };
    // Signal 模式：先把本地消息行插入（SENDING 状态），保证气泡总是出现，
    // 再异步发送 WS。即使网络/加密失败，本地也能看到消息（标 failed）。
    await _db.insertMessage({
      'id': messageId,
      'conversation_id': _conversationId,
      'direction': 'outgoing',
      'kind': isEmoji ? 'emoji' : 'text',
      'body': body,
      'status': 'sending',
      'expires_in_seconds': expiresInSeconds,
      'expires_at': expiresInSeconds > 0
          ? DateTime.now().millisecondsSinceEpoch + expiresInSeconds * 1000
          : null,
      'sent_at': DateTime.now().millisecondsSinceEpoch,
    });
    await _touchConversation(body, messageId);

    try {
      final sig = ChatSignal(
        type: ChatSignalType.chatMessage,
        fromUserId: _localUserId,
        toUserId: _remoteUserId,
        messageId: messageId,
        payload: payload,
      );
      final sent = _signaling.sendChatSignal(sig);
      // 发送成功 → 更新状态 sent；WS 未连接 → 标记 failed，用户可见。
      await _db.updateMessageStatus(messageId, sent ? 'sent' : 'failed');
      if (!sent) {
        return {'error': 'WS 未连接，消息未发出'};
      }
    } catch (e) {
      await _db.updateMessageStatus(messageId, 'failed');
      return {'error': 'send failed: $e'};
    }

    return {'message_id': messageId};
  }

  /// 处理入站 chatMessage（解密、入库、回执、阅后即焚）。
  Future<void> handleIncoming(ChatSignal signal) async {
    await _ensureConversation();
    final payload = signal.payload ?? const {};
    final messageId =
        payload['message_id'] as String? ?? signal.messageId ?? _newId();

    // 已有记录（离线队列重投/回执重放）→ 忽略。
    if (await _db.getMessage(messageId) != null) return;

    final ciphertextB64 = payload['ciphertext'] as String?;
    final counter = (payload['counter'] as num?)?.toInt();
    if (ciphertextB64 == null || counter == null) return;

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

    final aad = ChatCrypto.associatedData(
      senderUserId: _remoteUserId,
      recipientUserId: _localUserId,
      conversationId: _conversationId,
    );
    final ChatCryptoDecryptResult dec;
    try {
      dec = await ChatCrypto.decryptMessage(
        session,
        base64Decode(ciphertextB64),
        messageId: messageId,
        counter: counter,
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

    // 附件元数据消息（含 transfer_id）：落附件表，等数据通道到达。
    final isFile = parsed.containsKey('transfer_id');
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.insertMessage({
      'id': messageId,
      'conversation_id': _conversationId,
      'direction': 'incoming',
      'kind': kind,
      'body': body,
      'status': isFile ? 'pending' : 'delivered',
      'expires_in_seconds': expiresIn,
      'expires_at': expiresIn > 0 ? now + expiresIn * 1000 : null,
      'received_at': now,
      'created_at': now,
    });

    if (isFile) {
      // 附件元数据：存 per-file AES key + 明文落盘路径，供 chatFileOffer 使用。
      final transferId = parsed['transfer_id'] as String? ?? messageId;
      final dir = await getApplicationDocumentsDirectory();
      final plainPath = '${dir.path}/chat_media/$_conversationId/$messageId';
      await _db.insertAttachment({
        'id': transferId,
        'message_id': messageId,
        'conversation_id': _conversationId,
        'kind': kind,
        'file_name': parsed['file_name'] as String? ?? body,
        'mime_type': parsed['mime_type'] as String? ?? 'application/octet-stream',
        'size_bytes': (parsed['size_bytes'] as num?)?.toInt() ?? 0,
        'plaintext_sha256': parsed['plaintext_sha256'] as String?,
        'local_plain_path': plainPath,
        'aes_key': base64Decode(parsed['aes_key'] as String? ?? ''),
        'status': 'pending',
      });
    }
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

  /// 发送阅后即焚设置变更（会话默认），并同步本地（避免轮询重置）。
  void sendDisappearingSetting(int seconds) {
    _db.upsertConversation({
      'id': _conversationId,
      'remote_user_id': _remoteUserId,
      'disappearing_seconds': seconds,
    });
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

  /// 确保 conversation 行存在（messages.conversation_id 有外键约束，
  /// 若发送前无该行，insertMessage 会失败导致本机看不到消息）。
  /// ★不吞异常：若 conversation 建失败（如 DB 表缺失），抛出让 sendText 标记
  ///   failed 并提示，避免「外键失败被静默吞掉 → 消息消失但无任何提示」。
  Future<void> _ensureConversation() async {
    final existing = await _db.getConversation(_conversationId);
    if (existing == null) {
      await _db.upsertConversation({
        'id': _conversationId,
        'remote_user_id': _remoteUserId,
      });
    }
  }

  Future<void> _touchConversation(String preview, String lastMessageId) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    // 保留已有 display_name：upsert 用 replace 会覆盖整行，若这里不带会清空名字。
    String? displayName;
    try {
      final existing = await _db.getConversation(_conversationId);
      displayName = existing?['remote_display_name'] as String?;
      if ((displayName == null || displayName.isEmpty) &&
          _remoteUserId.isNotEmpty) {
        final contact = await _db.getContact(_remoteUserId);
        if (contact != null) {
          displayName = contact['display_name'] as String?;
        }
      }
    } catch (_) {}
    await _db.upsertConversation({
      'id': _conversationId,
      'remote_user_id': _remoteUserId,
      'remote_display_name': displayName,
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

  // ---- 附件（图片/文件）发送与接收 ----

  /// 发送图片/文件：加密源文件 → 棘轮加密元数据 chatMessage → 数据通道传输。
  /// [filePath] 本地源文件，[kind] image/file/video。
  Future<Map<String, dynamic>?> sendFile({
    required String filePath,
    required String kind, // image / file / video
    required String fileName,
    required String mimeType,
    int expiresInSeconds = 0,
  }) async {
    await _ensureConversation();
    final src = File(filePath);
    if (!await src.exists()) return {'error': 'file not found'};

    var session = await _sessions.loadSession(_conversationId);
    Map<String, dynamic>? initPayload;
    if (session == null) {
      try {
        initPayload = await _sessions.establishAsInitiator(
          remoteUserId: _remoteUserId,
          conversationId: _conversationId,
        );
        session = await _sessions.loadSession(_conversationId);
      } catch (e) {
        return {'error': 'no session: $e'};
      }
    }

    final messageId = _newId();
    final transferId = messageId; // 附件与消息共用 id
    final aesKey = CryptoManager.randomBytes(32);
    final dir = await getApplicationDocumentsDirectory();
    final encPath =
        '${dir.path}/chat_media/$_conversationId/$messageId.enc';
    final plaintextSha = await _sha256File(src);

    // 1) 棘轮加密元数据（不含文件字节，只含定位 + 密钥）。
    final meta = {
      'kind': kind,
      'body': fileName,
      'transfer_id': transferId,
      'file_name': fileName,
      'mime_type': mimeType,
      'size_bytes': await src.length(),
      'plaintext_sha256': plaintextSha,
      'aes_key': base64Encode(aesKey),
    };
    final aad = ChatCrypto.associatedData(
      senderUserId: _localUserId,
      recipientUserId: _remoteUserId,
      conversationId: _conversationId,
    );
    if (session == null) return {'error': 'session unavailable'};
    final enc = await ChatCrypto.encryptMessage(
      session,
      utf8.encode(jsonEncode(meta)),
      messageId: messageId,
      aad: aad,
    );
    await _sessions.saveSession(_conversationId, enc.session);

    // 2) 先插本地附件消息行（Signal 模式），保证气泡总是出现。
    await _db.insertMessage({
      'id': messageId,
      'conversation_id': _conversationId,
      'direction': 'outgoing',
      'kind': kind,
      'body': fileName,
      'status': 'pending',
      'expires_in_seconds': expiresInSeconds,
      'transfer_id': transferId,
      'sent_at': DateTime.now().millisecondsSinceEpoch,
    });

    // 3) 发送元数据 chatMessage（密文里只有元数据，无文件内容）。
    _signaling.sendChatSignal(ChatSignal(
      type: ChatSignalType.chatMessage,
      fromUserId: _localUserId,
      toUserId: _remoteUserId,
      messageId: messageId,
      payload: {
        'message_id': messageId,
        'ciphertext': base64Encode(enc.ciphertext),
        'counter': enc.counter,
        'expires_in_seconds': expiresInSeconds,
        if (initPayload != null) 'init_payload': initPayload,
      },
    ));
    await _db.insertAttachment({
      'id': transferId,
      'message_id': messageId,
      'conversation_id': _conversationId,
      'kind': kind,
      'file_name': fileName,
      'mime_type': mimeType,
      'size_bytes': await src.length(),
      'plaintext_sha256': plaintextSha,
      'local_enc_path': encPath,
      'local_plain_path': filePath,
      'aes_key': aesKey,
      'status': 'pending',
    });
    await _touchConversation(fileName, messageId);

    // 4) 启动数据通道传输（密文，服务器不见字节）。
    fileManager.sendFile(
      transferId: transferId,
      filePath: filePath,
      fileName: fileName,
      mimeType: mimeType,
      aesKey: aesKey,
      encPath: encPath,
    );

    return {'message_id': messageId};
  }

  /// 处理入站 chatFileOffer（接收方回 answer）。
  Future<void> handleFileOffer(ChatSignal signal) async {
    final payload = signal.payload ?? const {};
    final transferId = payload['transfer_id'] as String?;
    final sdp = payload['sdp'] as String?;
    if (transferId == null || sdp == null) return;

    final attach = await _db.getAttachment(transferId);
    if (attach == null) return;
    final aesKey = attach['aes_key'] as List<int>?;
    if (aesKey == null) return;

    await _db.updateAttachmentStatus(transferId, 'transferring');
    await _db.updateMessageStatus(transferId, 'pending');

    final dir = await getApplicationDocumentsDirectory();
    final plainPath = attach['local_plain_path'] as String? ??
        '${dir.path}/chat_media/$_conversationId/$transferId';

    await fileManager.handleOffer(
      transferId: transferId,
      sdp: sdp,
      fileName: attach['file_name'] as String? ?? 'file',
      totalBytes: (attach['size_bytes'] as num?)?.toInt() ?? 0,
      mimeType: attach['mime_type'] as String? ?? 'application/octet-stream',
      filePath: plainPath,
      aesKey: Uint8List.fromList(aesKey),
    );
  }

  /// 处理入站 chatFileAnswer / chatFileIce（发送方侧）。
  Future<void> handleFileSignal(ChatSignal signal) async {
    final payload = signal.payload ?? const {};
    final sdp = payload['sdp'] as String?;
    if (signal.type == ChatSignalType.chatFileAnswer && sdp != null) {
      await fileManager.handleAnswer(
        payload['transfer_id'] as String? ?? '',
        sdp,
      );
    } else if (signal.type == ChatSignalType.chatFileIce) {
      await fileManager.handleIceCandidate(
        payload['transfer_id'] as String? ?? '',
        payload,
      );
    }
  }

  /// 数据通道进度回调：传输完成/失败时更新消息状态。
  Future<void> _onFileProgress(
      ChatFileTransfer transfer, double progress, String status) async {
    final messageId = transfer.transferId;
    if (status == kDone) {
      await _db.updateMessageStatus(messageId, 'delivered');
      await _db.updateAttachmentStatus(messageId, 'done');
    } else if (status == kFailed) {
      await _db.updateMessageStatus(messageId, 'failed');
      await _db.updateAttachmentStatus(messageId, 'failed');
    }
  }

  Future<String> _sha256File(File file) async {
    final bytes = await file.readAsBytes();
    return crypto.sha256.convert(bytes).toString();
  }
}
