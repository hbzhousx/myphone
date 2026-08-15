/// 简化聊天加密：复用语音的 X3DH 对称方案（区别于旧的完整双棘轮）。
///
/// 一次 X3DH 协商出 32 字节会话密钥（sessionKey），持久化在 SQLCipher。
/// 每条消息用独立消息密钥 = HKDF(sessionKey, "MyPhone-Chat-Msg-v1:<messageId>", 32)，
/// 随机 12B nonce + AES-256-GCM，counter 绑定进 AAD 防重放/重排。
///
/// 相比双棘轮：无链密钥、无 DH ratchet、无 skipped-map，代码量大幅减少，
/// 且与语音共用同一套 X3DH 原语，可靠性更高（消除了 SPK 棘轮不匹配等故障类）。
/// 代价：单会话密钥泄露可解密全部历史消息（无前向保密）——用户明确选择简化。
library;

import 'dart:typed_data';

import 'crypto_manager.dart';

/// 乱序容忍窗口：允许接收方落后对端最多这么多条。
const int kChatMaxOutOfOrder = 100;

class ChatCryptoException implements Exception {
  final String message;
  const ChatCryptoException(this.message);
  @override
  String toString() => 'ChatCryptoException: $message';
}

/// 会话状态（持久化到 SQLCipher session_json）。
class ChatCryptoSession {
  /// X3DH 协商出的 32B 会话密钥。
  final Uint8List sessionKey;

  /// 下一条发送将使用的 counter（从 1 开始）。
  final int sendCounter;

  /// 已连续接收的最高 counter（从 0 开始）。
  final int recvCounter;

  /// 对端身份公钥（诊断用）。
  final Uint8List? remoteIdentityPub;

  /// 乱序收到的、高于 recvCounter 的 counter（防重复）。
  final Set<int> recvSeenCounters;

  const ChatCryptoSession({
    required this.sessionKey,
    this.sendCounter = 1,
    this.recvCounter = 0,
    this.remoteIdentityPub,
    this.recvSeenCounters = const {},
  });

  Map<String, dynamic> toJson() => {
        'session_key': _hex(sessionKey),
        'send_counter': sendCounter,
        'recv_counter': recvCounter,
        'remote_identity_pub':
            remoteIdentityPub != null ? _hex(remoteIdentityPub!) : null,
        'recv_seen_counters': (recvSeenCounters.toList()..sort()),
      };

  static ChatCryptoSession fromJson(Map<String, dynamic> json) {
    final keyHex = json['session_key'];
    if (keyHex is! String || keyHex.isEmpty) {
      throw ChatCryptoException('invalid session: missing session_key');
    }
    return ChatCryptoSession(
      sessionKey: _fromHex(keyHex),
      sendCounter: (json['send_counter'] as num?)?.toInt() ?? 1,
      recvCounter: (json['recv_counter'] as num?)?.toInt() ?? 0,
      remoteIdentityPub: (json['remote_identity_pub'] as String?) != null
          ? _fromHex(json['remote_identity_pub'] as String)
          : null,
      recvSeenCounters: ((json['recv_seen_counters'] as List?) ?? const [])
          .map((e) => (e as num).toInt())
          .toSet(),
    );
  }

  ChatCryptoSession copyWith({
    int? sendCounter,
    int? recvCounter,
    Set<int>? recvSeenCounters,
  }) =>
      ChatCryptoSession(
        sessionKey: sessionKey,
        sendCounter: sendCounter ?? this.sendCounter,
        recvCounter: recvCounter ?? this.recvCounter,
        remoteIdentityPub: remoteIdentityPub,
        recvSeenCounters: recvSeenCounters ?? this.recvSeenCounters,
      );

  static String _hex(List<int> b) =>
      b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();

  static Uint8List _fromHex(String h) {
    final out = Uint8List(h.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(h.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }
}

/// 加密结果。
class ChatCryptoEncryptResult {
  /// nonce(12) || ct || mac。
  final Uint8List ciphertext;
  final int counter;
  final ChatCryptoSession session;
  const ChatCryptoEncryptResult({
    required this.ciphertext,
    required this.counter,
    required this.session,
  });
}

/// 解密结果。
class ChatCryptoDecryptResult {
  final Uint8List plaintext;
  final ChatCryptoSession session;
  const ChatCryptoDecryptResult({
    required this.plaintext,
    required this.session,
  });
}

class ChatCrypto {
  static const _nonceLength = 12;
  static const _infoPrefix = 'MyPhone-Chat-Msg-v1:';

  /// 会话绑定 AAD（防跨会话重放）。
  ///
  /// ★AAD 必须**加解密两端完全一致**，否则 AES-GCM 认证失败（MAC 错误）。
  ///   但 sender/recipient 是各端视角（会互换），conversationId 是
  ///   `conv-<对端id>`（也互换）——若直接用，发送方 AAD=...:conv-A、接收方
  ///   AAD=...:conv-B，两端 AAD 不同 → 每条消息解密失败、两端都看不到。
  ///   修复：对双方 user id 排序得到规范形式（唯一标识这对用户的会话，
  ///   天然防跨会话重放），不再依赖不对称的 conversationId。
  static Uint8List associatedData({
    required String senderUserId,
    required String recipientUserId,
    required String conversationId,
  }) {
    final ids = [senderUserId, recipientUserId]..sort();
    return Uint8List.fromList(
      'MyPhone-Chat-v1:${ids[0]}:${ids[1]}'.codeUnits,
    );
  }

  /// 用 X3DH 协商出的 sessionKey 初始化会话（发起/响应方共用）。
  static ChatCryptoSession initSession(
    List<int> sessionKey, {
    List<int>? remoteIdentityPub,
  }) {
    return ChatCryptoSession(
      sessionKey: Uint8List.fromList(sessionKey),
      remoteIdentityPub:
          remoteIdentityPub != null ? Uint8List.fromList(remoteIdentityPub) : null,
    );
  }

  /// 加密一条消息。返回更新后的会话（sendCounter+1，必须持久化）。
  static Future<ChatCryptoEncryptResult> encryptMessage(
    ChatCryptoSession session,
    List<int> plaintext, {
    required String messageId,
    required List<int> aad,
  }) async {
    final counter = session.sendCounter;
    final messageKey = await CryptoManager.hkdf(
      session.sessionKey,
      '$_infoPrefix$messageId',
      32,
    );
    final fullAad = _withCounter(aad, counter);
    final nonce = CryptoManager.randomNonce12();
    final ciphertext = await CryptoManager.aesGcmEncrypt(
      plaintext,
      key: messageKey,
      nonce: nonce,
      aad: fullAad,
    );
    return ChatCryptoEncryptResult(
      ciphertext: ciphertext,
      counter: counter,
      session: session.copyWith(sendCounter: counter + 1),
    );
  }

  /// 解密一条消息。counter 单调递增校验 + 乱序窗口容忍。
  /// MAC 失败/重放/超窗 → 抛 [ChatCryptoException]，会话不回卷（调用方不持久化）。
  static Future<ChatCryptoDecryptResult> decryptMessage(
    ChatCryptoSession session,
    List<int> ciphertext, {
    required String messageId,
    required int counter,
    required List<int> aad,
  }) async {
    // 重放 / 过期。
    if (counter <= session.recvCounter) {
      throw ChatCryptoException('replay or old message (counter=$counter)');
    }
    // 窗口内重复。
    if (session.recvSeenCounters.contains(counter)) {
      throw ChatCryptoException('duplicate out-of-order message');
    }
    // 超窗（DoS 防护）。
    if (counter > session.recvCounter + kChatMaxOutOfOrder) {
      throw ChatCryptoException('counter too far ahead');
    }

    final messageKey = await CryptoManager.hkdf(
      session.sessionKey,
      '$_infoPrefix$messageId',
      32,
    );
    final fullAad = _withCounter(aad, counter);

    final Uint8List plaintext;
    try {
      plaintext = await CryptoManager.aesGcmDecrypt(
        ciphertext,
        key: messageKey,
        nonceLength: _nonceLength,
        aad: fullAad,
      );
    } catch (e) {
      throw ChatCryptoException('decrypt failed: $e');
    }

    // 推进接收状态。
    var recvCounter = session.recvCounter;
    var seen = Set<int>.from(session.recvSeenCounters);
    if (counter == recvCounter + 1) {
      recvCounter = counter;
      // 若窗口内已缓存连续后继，一并推进。
      while (seen.contains(recvCounter + 1)) {
        recvCounter = recvCounter + 1;
        seen.remove(recvCounter);
      }
    } else {
      seen.add(counter);
    }

    return ChatCryptoDecryptResult(
      plaintext: plaintext,
      session: session.copyWith(
        recvCounter: recvCounter,
        recvSeenCounters: seen,
      ),
    );
  }

  static Uint8List _withCounter(List<int> aad, int counter) {
    final suffix = '|counter=$counter'.codeUnits;
    final out = Uint8List(aad.length + suffix.length);
    out.setRange(0, aad.length, aad);
    out.setRange(aad.length, out.length, suffix);
    return out;
  }
}
