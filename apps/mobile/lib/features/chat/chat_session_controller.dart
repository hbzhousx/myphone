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
import '../../core/network/api_client.dart';
import '../../core/network/chat_signal.dart';
import '../../core/network/signaling_client.dart';
import '../../core/storage/database.dart';

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

  ApiClient? _api;
  ApiClient get _apiClient => _api ??= ApiClient();

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
      // 附件元数据：存 per-file AES key + 下载 URL + 明文落盘路径。
      // Signal 范式：发送方上传密文到服务器，接收方下载密文本地解密。
      final transferId = parsed['transfer_id'] as String? ?? messageId;
      final dir = await getApplicationDocumentsDirectory();
      final plainPath = '${dir.path}/chat_media/$_conversationId/$messageId';
      final aesKeyB64 = parsed['aes_key'] as String? ?? '';
      final aesNonceB64 = parsed['aes_nonce'] as String? ?? '';
      final downloadUrl = parsed['attachment_url'] as String?;
      // 安全 base64 解码：非法时不影响整个 handleIncoming（否则附件行插不进、
      // 下载不触发、文件打不开）。失败报诊断定位。
      Uint8List? aesKeyBytes;
      Uint8List? aesNonceBytes;
      try {
        if (aesKeyB64.isNotEmpty) aesKeyBytes = base64Decode(aesKeyB64);
        if (aesNonceB64.isNotEmpty) aesNonceBytes = base64Decode(aesNonceB64);
      } catch (e) {
        _reportDiag('file:http-base64-fail',
            {'msg': messageId, 'err': '$e', 'keyLen': aesKeyB64.length});
      }
      // 诊断：附件分支入口（定位接收方是否进分支、downloadUrl 是否有值）。
      _reportDiag('file:http-attach', {
        'msg': messageId,
        'hasUrl': downloadUrl != null,
        'hasKey': aesKeyBytes != null,
        'hasNonce': aesNonceBytes != null,
        'hasId': parsed['attachment_id'] != null,
        'kind': kind,
      });
      // Signal 式：落库附件记录（失败不致命，仍尝试触发下载）。
      // try-catch 确保列缺失/约束等 DB 异常不中断 handleIncoming、不吞下载。
      var inserted = false;
      try {
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
          'aes_key': aesKeyBytes ?? const <int>[],
          if (downloadUrl != null) 'download_url': downloadUrl,
          'status': downloadUrl != null ? 'downloading' : 'pending',
        });
        inserted = true;
      } catch (e) {
        _reportDiag('file:http-insert-fail', {'msg': messageId, 'err': '$e'});
      }
      // 后台下载密文 → 本地解密写盘。不阻塞 handleIncoming（消息先显示）。
      // 即使落库失败也触发下载（Signal AttachmentDownloadJob：下载独立于落库）。
      if (downloadUrl != null && aesKeyBytes != null) {
        _downloadAttachmentFireAndForget(
          messageId: messageId,
          transferId: transferId,
          url: downloadUrl,
          plainPath: plainPath,
          aesKey: aesKeyBytes,
          aesNonce: aesNonceBytes,
        );
      } else {
        _reportDiag('file:http-no-url', {'msg': messageId, 'hasUrl': downloadUrl != null});
      }
    }
    await _touchConversation(body, messageId);

    // 回执：delivered（已读回执由 UI 显式触发 markRead）。
    _sendReceipt(messageId, 'delivered');
  }

  /// Signal 式独立附件指针处理：chatAttachment 信令解密 → 落库消息+附件 → 触发下载。
  /// 不经过 chatMessage body 解析（Signal MessageContentProcessor 专门处理附件）。
  /// [signal] payload：{message_id, ciphertext(棘轮密文=附件指针JSON), counter, transfer_id}。
  Future<void> handleAttachmentSignal(ChatSignal signal) async {
    final payload = signal.payload ?? const {};
    final messageId = payload['message_id'] as String? ?? signal.messageId ?? _newId();
    final ciphertextB64 = payload['ciphertext'] as String?;
    final counter = (payload['counter'] as num?)?.toInt();
    final transferId = payload['transfer_id'] as String? ?? messageId;
    if (ciphertextB64 == null || counter == null) {
      _reportDiag('file:http-pointer-bad', {'msg': messageId, 'hasCipher': ciphertextB64 != null, 'counter': counter});
      return;
    }

    // 用本会话棘轮解密附件指针（与 handleIncoming 同会话）。
    var session = await _sessions.loadSession(_conversationId);
    if (session == null) {
      _reportDiag('file:http-pointer-no-session', {'msg': messageId});
      return;
    }
    final aad = ChatCrypto.associatedData(
      senderUserId: _remoteUserId,
      recipientUserId: _localUserId,
      conversationId: _conversationId,
    );
    Map<String, dynamic> pointer;
    try {
      final dec = await ChatCrypto.decryptMessage(
        session,
        base64Decode(ciphertextB64),
        messageId: messageId,
        counter: counter,
        aad: aad,
      );
      await _sessions.saveSession(_conversationId, dec.session);
      pointer = jsonDecode(utf8.decode(dec.plaintext)) as Map<String, dynamic>;
    } catch (e) {
      // 解密失败。可能：①会话不同步（对端 SPK 变更）；②chatAttachment 先于
      //   chatMessage 到达（WS 乱序），本会话 counter 还没推进到 pointer 的 counter。
      //   Signal 无此问题（body+attachments 在同一 DataMessage），我们两条信令
      //   故需等待重试：给 chatMessage 处理留时间（Signal EarlyMessageCache 语义）。
      //   最多重试 5 次 × 400ms = 2s，之后才尝试 init_payload 重建。
      Map<String, dynamic>? retried;
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
        final s2 = await _sessions.loadSession(_conversationId);
        if (s2 == null) break;
        try {
          final dec2 = await ChatCrypto.decryptMessage(
            s2,
            base64Decode(ciphertextB64),
            messageId: messageId,
            counter: counter,
            aad: aad,
          );
          await _sessions.saveSession(_conversationId, dec2.session);
          retried = jsonDecode(utf8.decode(dec2.plaintext)) as Map<String, dynamic>;
          _reportDiag('file:http-pointer-retry-ok', {'msg': messageId, 'attempt': i + 1});
          break;
        } catch (_) {
          // 仍失败，继续等。
        }
      }
      if (retried != null) {
        pointer = retried;
      } else {
        // 重试耗尽 → init_payload 重建（对端可能已换 SPK）。
        final initPayload = payload['init_payload'] as Map<String, dynamic>?;
        if (initPayload == null || initPayload.isEmpty) {
          _reportDiag('file:http-pointer-decrypt-fail', {'msg': messageId, 'err': '$e'});
          return;
        }
        try {
          final resp = await _sessions.establishAsResponder(
            remoteUserId: _remoteUserId,
            conversationId: _conversationId,
            initPayload: initPayload,
          );
          session = resp.session;
          final dec = await ChatCrypto.decryptMessage(
            session,
            base64Decode(ciphertextB64),
            messageId: messageId,
            counter: counter,
            aad: aad,
          );
          await _sessions.saveSession(_conversationId, dec.session);
          pointer = jsonDecode(utf8.decode(dec.plaintext)) as Map<String, dynamic>;
        } catch (e2) {
          _reportDiag('file:http-pointer-reestablish-fail', {'msg': messageId, 'err': '$e2'});
          return;
        }
      }
    }

    final kind = pointer['kind'] as String? ?? 'file';
    final fileName = pointer['file_name'] as String? ?? pointer['body'] as String? ?? 'file';
    final downloadUrl = pointer['attachment_url'] as String?;
    final aesKeyB64 = pointer['aes_key'] as String? ?? '';
    final aesNonceB64 = pointer['aes_nonce'] as String? ?? '';
    Uint8List? aesKeyBytes;
    Uint8List? aesNonceBytes;
    try {
      if (aesKeyB64.isNotEmpty) aesKeyBytes = base64Decode(aesKeyB64);
      if (aesNonceB64.isNotEmpty) aesNonceBytes = base64Decode(aesNonceB64);
    } catch (e) {
      _reportDiag('file:http-pointer-base64-fail', {'msg': messageId, 'err': '$e'});
    }
    _reportDiag('file:http-pointer', {
      'msg': messageId,
      'hasUrl': downloadUrl != null,
      'hasKey': aesKeyBytes != null,
      'kind': kind,
    });

    final now = DateTime.now().millisecondsSinceEpoch;
    // 落库消息行（附件消息，pending 直到下载完成）。
    try {
      await _db.insertMessage({
        'id': messageId,
        'conversation_id': _conversationId,
        'direction': 'incoming',
        'kind': kind,
        'body': fileName,
        'status': 'pending',
        'received_at': now,
        'created_at': now,
        'transfer_id': transferId,
      });
    } catch (e) {
      _reportDiag('file:http-pointer-msg-insert-fail', {'msg': messageId, 'err': '$e'});
    }
    // 落库附件行（带 download_url）。
    final dir = await getApplicationDocumentsDirectory();
    final plainPath = '${dir.path}/chat_media/$_conversationId/$messageId';
    var inserted = false;
    try {
      await _db.insertAttachment({
        'id': transferId,
        'message_id': messageId,
        'conversation_id': _conversationId,
        'kind': kind,
        'file_name': fileName,
        'mime_type': pointer['mime_type'] as String? ?? 'application/octet-stream',
        'size_bytes': (pointer['size_bytes'] as num?)?.toInt() ?? 0,
        'plaintext_sha256': pointer['plaintext_sha256'] as String?,
        'local_plain_path': plainPath,
        'aes_key': aesKeyBytes ?? const <int>[],
        if (downloadUrl != null) 'download_url': downloadUrl,
        'status': downloadUrl != null ? 'downloading' : 'pending',
      });
      inserted = true;
    } catch (e) {
      _reportDiag('file:http-pointer-attach-insert-fail', {'msg': messageId, 'err': '$e'});
    }
    _reportDiag('file:http-pointer-inserted', {'msg': messageId, 'inserted': inserted});

    // Signal 式：落库后立即触发下载（AttachmentDownloadJob），独立 job。
    if (downloadUrl != null && aesKeyBytes != null) {
      _downloadAttachmentFireAndForget(
        messageId: messageId,
        transferId: transferId,
        url: downloadUrl,
        plainPath: plainPath,
        aesKey: aesKeyBytes,
        aesNonce: aesNonceBytes,
      );
    } else {
      _reportDiag('file:http-pointer-no-download', {
        'msg': messageId,
        'hasUrl': downloadUrl != null,
        'hasKey': aesKeyBytes != null,
      });
    }
  }

  /// 后台下载附件密文 → AES-GCM 解密 → 写盘（fire-and-forget，不阻塞消息显示）。
  void _downloadAttachmentFireAndForget({
    required String messageId,
    required String transferId,
    required String url,
    required String plainPath,
    required List<int> aesKey,
    required List<int>? aesNonce,
  }) {
    // 每个附件一个独立异步任务，失败不影响其他附件/消息。
    // ignore: discarded_futures
    _downloadAttachment(
      messageId: messageId,
      transferId: transferId,
      url: url,
      plainPath: plainPath,
      aesKey: aesKey,
      aesNonce: aesNonce,
    ).catchError((Object e) {
      debugPrint('[RECV] download attachment failed: $e');
      _reportDiag('file:http-download-fail', {'msg': messageId, 'err': '$e'});
      try {
        _db.updateAttachmentStatus(transferId, 'failed');
      } catch (_) {}
    }, test: (Object e) {
      // 过滤非错误（如取消），避免误报。
      return e is Error || e is Exception;
    });
  }

  /// 下载密文 → 解密 → 写盘 → 更新状态。服务器只见密文，密钥本地解。
  Future<void> _downloadAttachment({
    required String messageId,
    required String transferId,
    required String url,
    required String plainPath,
    required List<int> aesKey,
    required List<int>? aesNonce,
  }) async {
    _reportDiag('file:http-download', {'msg': messageId, 'url': url});
    final ciphertext = await _apiClient.downloadAttachment(url);
    _reportDiag('file:http-downloaded', {'msg': messageId, 'encBytes': ciphertext.length});

    final nonce = aesNonce ?? Uint8List.sublistView(ciphertext, 0, 12);
    final plainBytes = await CryptoManager.aesGcmDecrypt(
      ciphertext,
      key: aesKey,
      nonceLength: aesNonce != null ? 12 : nonce.length,
      aad: Uint8List.fromList('myphone-file-v1'.codeUnits),
    );
    final plainFile = File(plainPath);
    await plainFile.parent.create(recursive: true);
    await plainFile.writeAsBytes(plainBytes);

    await _db.updateAttachmentStatus(transferId, 'done');
    await _db.updateMessageStatus(messageId, 'delivered',
        deliveredAt: DateTime.now().millisecondsSinceEpoch);
    _reportDiag('file:http-download-done', {
      'msg': messageId,
      'plainBytes': plainBytes.length,
      'exists': plainFile.existsSync(),
    });

    // 下载完成即删服务器密文（释放空间；失败不影响本地，忽略）。
    try {
      await _apiClient.deleteAttachment(url);
    } catch (e) {
      _reportDiag('file:http-delete-fail', {'msg': messageId, 'err': '$e'});
    }
  }

  /// Signal 式独立下载扫描：扫描本会话所有 status=downloading 的附件并逐个下载。
  /// 与 handleIncoming 解耦——即使消息解密/落库链路某处异常，路由后调用本方法
  /// 仍会触发下载（Signal AttachmentDownloadJob 语义：附件下载是独立 job）。
  /// 幂等：已 done/failed 的附件跳过；下载中/失败下次再扫。
  Future<void> maybeDownloadAttachments() async {
    try {
      final pendings = await _db.getPendingDownloads(_conversationId);
      for (final att in pendings) {
        final transferId = att['id'] as String;
        final url = att['download_url'] as String?;
        final aesKey = att['aes_key'] as List<int>?;
        final plainPath = att['local_plain_path'] as String?;
        final messageId = att['message_id'] as String?;
        if (url == null || aesKey == null || aesKey.isEmpty || plainPath == null) {
          // 缺下载所需信息（旧数据/字段缺失）→ 标记 failed，避免死循环扫描。
          _reportDiag('file:http-scan-skip', {
            'tid': transferId,
            'hasUrl': url != null,
            'hasKey': aesKey != null && aesKey.isNotEmpty,
            'hasPath': plainPath != null,
          });
          await _db.updateAttachmentStatus(transferId, 'failed');
          continue;
        }
        if (messageId == null) continue;
        // 已有明文文件 → 直接 done（重扫幂等）。
        final f = File(plainPath);
        if (f.existsSync() && f.lengthSync() > 0) {
          await _db.updateAttachmentStatus(transferId, 'done');
          continue;
        }
        _downloadAttachmentFireAndForget(
          messageId: messageId,
          transferId: transferId,
          url: url,
          plainPath: plainPath,
          aesKey: aesKey,
          aesNonce: null,
        );
      }
    } catch (e, st) {
      // unawaited 调用会吞异常——这里必须兜底上报，否则扫描失败静默。
      _reportDiag('file:http-scan-error', {'err': '$e', 'stack': '$st'});
    }
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
    final aesNonce = CryptoManager.randomNonce12();
    _reportDiag('file:aes-key-send', {
      'msg': messageId,
      'len': aesKey.length,
      'fp': _fp(aesKey),
    });

    // 1) 读源文件 → 整文件 AES-GCM 加密（服务器中转只传密文，服务器不见明文）。
    // 诊断：读文件+加密（定位 sendFile 卡在读文件还是加密）。
    _reportDiag('file:http-encrypt-start', {'msg': messageId, 'size': await src.length()});
    final plainBytes = await src.readAsBytes();
    final plaintextSha = crypto.sha256.convert(plainBytes).toString();
    final ciphertext = await CryptoManager.aesGcmEncrypt(
      plainBytes,
      key: aesKey,
      nonce: aesNonce,
      aad: Uint8List.fromList('myphone-file-v1'.codeUnits),
    );
    _reportDiag('file:http-encrypted', {'msg': messageId, 'plainBytes': plainBytes.length, 'encBytes': ciphertext.length});

    // 2) 上传密文到服务器（Signal 附件 CDN 同理：只存密文）。拿下载 URL。
    _reportDiag('file:http-upload-start', {'msg': messageId});
    String attachmentUrl;
    String attachmentId;
    try {
      final up = await _apiClient.uploadAttachment(ciphertext, fileName);
      attachmentUrl = up['url'] as String? ?? '/v1/attachments/${up['attachment_id']}';
      attachmentId = up['attachment_id'] as String? ?? transferId;
      _reportDiag('file:http-uploaded', {'msg': messageId, 'url': attachmentUrl, 'id': attachmentId});
    } catch (e) {
      debugPrint('[SEND] upload attachment failed: $e');
      _reportDiag('file:http-upload-fail', {'msg': messageId, 'err': '$e'});
      // 上传失败：插本地 failed 行让用户可见，不静默丢。
      await _db.insertMessage({
        'id': messageId,
        'conversation_id': _conversationId,
        'direction': 'outgoing',
        'kind': kind,
        'body': fileName,
        'status': 'failed',
        'transfer_id': transferId,
        'sent_at': DateTime.now().millisecondsSinceEpoch,
      });
      await _touchConversation(fileName, messageId);
      return {'error': 'attachment upload failed: $e'};
    }

    // 3) Signal 式：单消息含完整 meta（Signal DataMessage = body + attachments 一体，
    //    一次 X3DH 一次加密，无双信令的会话/MAC 问题）。meta 含附件指针（URL+密钥）。
    final aad = ChatCrypto.associatedData(
      senderUserId: _localUserId,
      recipientUserId: _remoteUserId,
      conversationId: _conversationId,
    );
    if (session == null) return {'error': 'session unavailable'};

    final meta = {
      'kind': kind,
      'body': fileName,
      'transfer_id': transferId,
      'attachment_id': attachmentId,
      'attachment_url': attachmentUrl,
      'file_name': fileName,
      'mime_type': mimeType,
      'size_bytes': plainBytes.length,
      'plaintext_sha256': plaintextSha,
      'aes_key': base64Encode(aesKey),
      'aes_nonce': base64Encode(aesNonce),
    };
    final enc = await ChatCrypto.encryptMessage(
      session,
      utf8.encode(jsonEncode(meta)),
      messageId: messageId,
      aad: aad,
    );
    await _sessions.saveSession(_conversationId, enc.session);

    // 4) 先插本地附件消息行（Signal 模式），保证气泡总是出现。
    await _db.insertMessage({
      'id': messageId,
      'conversation_id': _conversationId,
      'direction': 'outgoing',
      'kind': kind,
      'body': fileName,
      'status': 'sent',
      'expires_in_seconds': expiresInSeconds,
      'transfer_id': transferId,
      'sent_at': DateTime.now().millisecondsSinceEpoch,
    });

    // 5) 发送 chatMessage（Signal 单消息：body + attachments 一体）。
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
    _reportDiag('file:http-sent', {'msg': messageId});

    // 7) 本地附件表：local_plain_path 指向源文件（发件方直接可预览）。
    await _db.insertAttachment({
      'id': transferId,
      'message_id': messageId,
      'conversation_id': _conversationId,
      'kind': kind,
      'file_name': fileName,
      'mime_type': mimeType,
      'size_bytes': plainBytes.length,
      'plaintext_sha256': plaintextSha,
      'local_enc_path': null,
      'local_plain_path': filePath,
      'aes_key': aesKey,
      'status': 'done',
    });
    await _touchConversation(fileName, messageId);

    return {'message_id': messageId};
  }

}
