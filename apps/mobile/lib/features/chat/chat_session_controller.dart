/// 单个会话的收发编排：棘轮加解密、消息入库、阅后即焚、回执生成。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path_provider/path_provider.dart';

import '../../core/crypto/chat_crypto.dart';
import '../../core/crypto/chat_session_manager.dart';
import '../../core/crypto/crypto_manager.dart';
import '../../core/network/chat_signal.dart';
import '../../core/network/signaling_client.dart';
import '../../core/storage/database.dart';
import 'chat_file_transfer_manager.dart';

/// chatDiag 统一开关（服务器 [CHAT-DIAG] 日志）。默认 ON 便于真机排查，
/// 调试完成后翻转为 false 可静默全部诊断上报（发送/接收/文件/ui）。
/// 一处控制，server 端 hub.go 无需改动。
const bool kChatDiag = true;

class ChatSessionController {
  final DatabaseManager _db;
  final ChatSessionManager _sessions;
  final SignalingClient _signaling;
  final String _localUserId;
  final String _remoteUserId;
  final String _conversationId;

  ChatFileTransferManager? _fileManager;

  /// 缓存本次会话的 init_payload（发起方 X3DH 输入），后续每条消息都带上，
  /// 接收方解密失败时可据此强制重建会话（Signal PreKeySignalMessage 语义）。
  Map<String, dynamic>? _initPayload;

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
        onDiag: (step, data) => _reportDiag(step, data),
      );

  /// 发送文本/表情消息。
  Future<Map<String, dynamic>?> sendText(
    String body, {
    int expiresInSeconds = 0,
  }) async {
    debugPrint('[SEND] sendText begin body=$body expires=$expiresInSeconds');
    await _ensureConversation();
    // ★每次发送都重新 X3DH 协商（Signal PreKeySignalMessage 语义）：
    //   重新取对端 bundle（当前 SPK/OTP 公钥）+ 新 ephemeral → 新会话 + 新
    //   init_payload。这样接收方每次都能用它重建到**匹配当前 SPK** 的会话。
    //   若复用旧会话，对端 SPK 变更后两端 key 不配对 → 解密 MAC 失败。
    var session;
    Map<String, dynamic>? initPayload;
    try {
      initPayload = await _sessions.establishAsInitiator(
        remoteUserId: _remoteUserId,
        conversationId: _conversationId,
      );
      // establishAsInitiator 已持久化新会话，重新加载。
      session = await _sessions.loadSession(_conversationId);
      if (session == null) return {'error': 'session unavailable'};
    } catch (e) {
      debugPrint('[SEND] establishAsInitiator failed: $e');
      return {'error': 'no session: $e'};
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
    _reportDiag('send:key-fp', {
      'msg': messageId,
      'fp': _fp(session.sessionKey),
      'counter': enc.counter,
      'their_spk': initPayload?['their_spk_fp'],
      'their_otp': initPayload?['their_otp_fp'],
      'their_ik': initPayload?['their_ik_fp'],
      'my_ik': initPayload?['my_ik_fp'],
      'my_ek': initPayload?['my_ek_fp'],
    });

    final payload = <String, dynamic>{
      'message_id': messageId,
      'ciphertext': base64Encode(enc.ciphertext),
      'counter': enc.counter,
      'expires_in_seconds': expiresInSeconds,
      if (initPayload != null) 'init_payload': initPayload,
    };
    // Signal 模式：先把本地消息行插入（SENDING 状态），保证气泡总是出现，
    // 再异步发送 WS。即使网络/加密失败，本地也能看到消息（标 failed）。
    debugPrint('[SEND] inserting local row id=$messageId');
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
    debugPrint('[SEND] local row inserted, touch conversation');
    await _touchConversation(body, messageId);

    try {
      final sig = ChatSignal(
        type: ChatSignalType.chatMessage,
        fromUserId: _localUserId,
        toUserId: _remoteUserId,
        messageId: messageId,
        payload: payload,
      );
      debugPrint('[SEND] sending over WS to=$_remoteUserId');
      final sent = await _signaling.sendChatSignal(sig);
      debugPrint('[SEND] WS send result=$sent');
      _reportDiag('send:ws-result', {'msg': messageId, 'sent': sent});
      // 发送成功 → 更新状态 sent；WS 未连接 → 标记 failed，用户可见。
      await _db.updateMessageStatus(messageId, sent ? 'sent' : 'failed');
      if (!sent) {
        return {'error': 'WS 未连接，消息未发出'};
      }
    } catch (e) {
      debugPrint('[SEND] WS send threw: $e');
      _reportDiag('send:ws-threw', {'msg': messageId, 'err': '$e'});
      await _db.updateMessageStatus(messageId, 'failed');
      return {'error': 'send failed: $e'};
    }

    return {'message_id': messageId};
  }

  /// 处理入站 chatMessage（解密、入库、回执、阅后即焚）。
  Future<void> handleIncoming(ChatSignal signal) async {
    debugPrint('[RECV] handleIncoming type=${signal.type} from=${signal.fromUserId}');
    _reportDiag('incoming:begin', {'from': signal.fromUserId});
    await _ensureConversation();
    final payload = signal.payload ?? const {};
    final messageId =
        payload['message_id'] as String? ?? signal.messageId ?? _newId();
    debugPrint('[RECV] messageId=$messageId');

    // 已有记录（离线队列重投/回执重放）→ 忽略。
    if (await _db.getMessage(messageId) != null) {
      debugPrint('[RECV] already have message, ignore');
      _reportDiag('incoming:dup-ignore', {'msg': messageId});
      return;
    }

    final ciphertextB64 = payload['ciphertext'] as String?;
    final counter = (payload['counter'] as num?)?.toInt();
    if (ciphertextB64 == null || counter == null) {
      debugPrint('[RECV] no ciphertext/counter, ignore');
      _reportDiag('incoming:no-cipher', {'msg': messageId});
      return;
    }

    var session = await _sessions.loadSession(_conversationId);
    if (session == null) {
      debugPrint('[RECV] no session, establishing as responder');
      _reportDiag('incoming:no-session', {'msg': messageId});
      try {
        final resp = await _sessions.establishAsResponder(
          remoteUserId: _remoteUserId,
          conversationId: _conversationId,
          initPayload:
              (payload['init_payload'] as Map<String, dynamic>?) ?? const {},
        );
        session = resp.session;
        _reportDiag('incoming:session-established',
            {'msg': messageId, 'my_spk': resp.spkFingerprint,
             'my_ik': resp.myIkFingerprint});
      } catch (e) {
        // 无法建立会话（身份变更等）——丢弃并标记 failed。
        debugPrint('[RECV] establishAsResponder failed: $e');
        _reportDiag('incoming:session-failed', {'msg': messageId, 'err': '$e'});
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
    ChatCryptoDecryptResult dec;
    try {
      dec = await ChatCrypto.decryptMessage(
        session,
        base64Decode(ciphertextB64),
        messageId: messageId,
        counter: counter,
        aad: aad,
      );
      _reportDiag('incoming:decrypted',
          {'msg': messageId, 'counter': counter, 'fp': _fp(session.sessionKey)});
    } catch (e) {
      // 解密失败。可能是旧会话残留/两端会话不同步。若消息带 init_payload，
      // 强制重建会话（Signal PreKeySignalMessage 语义）再重试一次。
      final initPayload = payload['init_payload'] as Map<String, dynamic>?;
      if (initPayload != null && initPayload.isNotEmpty) {
        debugPrint('[RECV] decrypt failed with old session, forcing re-establish with init_payload');
        _reportDiag('incoming:re-establish', {'msg': messageId});
        try {
          final resp = await _sessions.establishAsResponder(
            remoteUserId: _remoteUserId,
            conversationId: _conversationId,
            initPayload: initPayload,
          );
          session = resp.session;
          _reportDiag('incoming:re-established',
              {'msg': messageId, 'my_spk': resp.spkFingerprint,
               'my_ik': resp.myIkFingerprint});
          dec = await ChatCrypto.decryptMessage(
            session,
            base64Decode(ciphertextB64),
            messageId: messageId,
            counter: counter,
            aad: aad,
          );
          _reportDiag('incoming:decrypted-after-reestablish', {'msg': messageId});
        } catch (e2) {
          debugPrint('[RECV] re-establish+decrypt failed: $e2');
          _reportDiag('incoming:reestablish-failed',
              {'msg': messageId, 'err': '$e2',
               'fp': session != null ? _fp(session.sessionKey) : 'null'});
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
      } else {
        // 无 init_payload 且旧会话解不了——记录 failed，不回卷链。
        debugPrint('[RECV] decrypt failed (no init_payload): $e');
        _reportDiag('incoming:decrypt-failed', {'msg': messageId, 'err': '$e'});
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
    await _sessions.saveSession(_conversationId, dec.session);

    final parsed = jsonDecode(utf8.decode(dec.plaintext)) as Map<String, dynamic>;
    final kind = parsed['kind'] as String? ?? 'text';
    final body = parsed['body'] as String? ?? '';
    final expiresIn = (payload['expires_in_seconds'] as num?)?.toInt() ?? 0;
    debugPrint('[RECV] decrypted kind=$kind body=$body isFile=${parsed.containsKey('transfer_id')}');
    _reportDiag('incoming:decrypted-body',
        {'msg': messageId, 'kind': kind, 'bodyLen': body.length, 'body': body.substring(0, body.length > 30 ? 30 : body.length)});

    // 附件元数据消息（含 transfer_id）：落附件表，等数据通道到达。
    // ★必须存 transfer_id：否则 _loadMessages 里 msg['transfer_id'] 为 null，
    //   查不到附件 → _attachment_path 不设置 → 接收方无法预览图片/文件。
    final isFile = parsed.containsKey('transfer_id');
    final transferId = parsed['transfer_id'] as String?;
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
      if (transferId != null) 'transfer_id': transferId,
    });
    debugPrint('[RECV] incoming row inserted');
    _reportDiag('incoming:inserted', {'msg': messageId, 'kind': kind});

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
    debugPrint('[RECV] sending receipt kind=$kind msgId=$messageId');
    _signaling.sendChatSignal(ChatSignal(
      type: ChatSignalType.chatReceipt,
      fromUserId: _localUserId,
      toUserId: _remoteUserId,
      messageId: messageId,
      payload: {'message_id': messageId, 'kind': kind},
    ));
  }

  /// 诊断上报：把接收处理的进度通过 chatDiag 发到服务器日志（服务器不转发）。
  /// 用于定位"消息收到但不显示"——每步调用，服务器 [CHAT-DIAG] 能看走到哪。
  /// 公开诊断上报（供 chat_screen 等 UI 层调用）。
  void reportDiagnostic(String step, Map<String, dynamic> data) {
    _reportDiag(step, data);
  }

  void _reportDiag(String step, Map<String, dynamic> data) {
    if (!kChatDiag) return;
    try {
      _signaling.sendChatSignal(ChatSignal(
        type: ChatSignalType.chatDiag,
        fromUserId: _localUserId,
        toUserId: _remoteUserId,
        payload: {'step': step, 'conv': _conversationId, ...data},
      ));
    } catch (_) {}
  }

  /// sessionKey 指纹（前 8 字节 hex）——两端对比是否一致，定位 X3DH 失配。
  String _fp(List<int> key) {
    final n = key.length < 8 ? key.length : 8;
    return key.sublist(0, n).map((e) => e.toRadixString(16).padLeft(2, '0')).join();
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
    // 保留已有 display_name / disappearing_seconds：upsert 用 replace 会覆盖
    // 整行，若这里不带会清空名字、并把阅后即焚设置静默重置为 0
    // （导致用户设的阅后即焚在发/收一条消息后莫名消失）。
    String? displayName;
    int? disappearingSeconds;
    try {
      final existing = await _db.getConversation(_conversationId);
      displayName = existing?['remote_display_name'] as String?;
      disappearingSeconds =
          (existing?['disappearing_seconds'] as num?)?.toInt();
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
      if (disappearingSeconds != null)
        'disappearing_seconds': disappearingSeconds,
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

    // ★每次发送都重新 X3DH 协商（同 sendText）：确保用对端当前 SPK/OTP 配对。
    var session;
    Map<String, dynamic>? initPayload;
    try {
      initPayload = await _sessions.establishAsInitiator(
        remoteUserId: _remoteUserId,
        conversationId: _conversationId,
      );
      session = await _sessions.loadSession(_conversationId);
      if (session == null) return {'error': 'session unavailable'};
    } catch (e) {
      return {'error': 'no session: $e'};
    }

    final messageId = _newId();
    final transferId = messageId; // 附件与消息共用 id
    final aesKey = CryptoManager.randomBytes(32);
    _reportDiag('file:aes-key-send', {
      'msg': messageId,
      'len': aesKey.length,
      'fp': _fp(aesKey),
    });
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
    if (transferId == null || sdp == null) {
      _reportDiag('file:offer-bad', {'transferId': transferId, 'hasSdp': sdp != null});
      return;
    }

    final attach = await _db.getAttachment(transferId);
    if (attach == null) {
      _reportDiag('file:offer-no-attach', {'transferId': transferId});
      return;
    }
    final aesKey = attach['aes_key'] as List<int>?;
    if (aesKey == null) return;
    // 诊断：上报接收方解密用的 aesKey 指纹（对比发送方加密 key，定位 MAC 失败）。
    _reportDiag('file:aes-key', {
      'msg': transferId,
      'len': aesKey.length,
      'fp': _fp(Uint8List.fromList(aesKey)),
    });

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
    // 诊断：上报数据通道传输结果（定位接收方无法预览图片——文件是否到达）。
    _reportDiag('file:progress', {
      'msg': messageId,
      'status': status,
      'progress': progress,
      'path': transfer.filePath,
      'exists': File(transfer.filePath).existsSync(),
    });
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
