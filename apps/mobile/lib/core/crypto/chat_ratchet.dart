/// 完整 Double Ratchet 状态机（Signal 模型），用于聊天端到端加密。
///
/// 与通话 E2EE 的简化棘轮（CryptoManager.ratchetEncrypt/Decrypt）不同，本实现：
/// - 解密侧实现完整 DH 棘轮（收到新对端棘轮公钥时推进 root key）
/// - `skippedMessageKeys` 支持乱序投递（跳过的消息密钥暂存）
/// - 明文头部携带 `{dh_pub, pn, n}`，AAD 绑定会话身份防跨会话重放
/// - nonce 使用 `Random.secure()` 真随机（修复旧 `_random12()` 弱熵源）
///
/// 会话状态可序列化持久化到 SQLCipher（见 chat_session_manager.dart）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:convert/convert.dart';

import 'crypto_manager.dart';

/// 跳过的消息密钥上限（Signal 默认）。超过则拒绝推进，防内存耗尽 DoS。
const int kMaxSkippedMessageKeys = 2000;

/// 一次棘轮加密的结果。
class ChatEncryptedFrame {
  /// 明文头部（UTF-8 JSON：`{dh_pub, pn, n}`），随密文传输。
  final Uint8List header;

  /// AES-256-GCM 密文（含 12B nonce 前缀 + 16B MAC）。
  final Uint8List ciphertext;

  const ChatEncryptedFrame({required this.header, required this.ciphertext});

  /// 序列化为单条字节流：`[headerLen(2B)][header][ciphertext]`。
  Uint8List toBytes() {
    final out = Uint8List(2 + header.length + ciphertext.length);
    out[0] = (header.length >> 8) & 0xFF;
    out[1] = header.length & 0xFF;
    out.setRange(2, 2 + header.length, header);
    out.setRange(2 + header.length, out.length, ciphertext);
    return out;
  }

  /// 从 [toBytes] 的字节流反序列化。
  static ChatEncryptedFrame fromBytes(Uint8List bytes) {
    final headerLen = (bytes[0] << 8) | bytes[1];
    return ChatEncryptedFrame(
      header: Uint8List.sublistView(bytes, 2, 2 + headerLen),
      ciphertext: Uint8List.sublistView(bytes, 2 + headerLen),
    );
  }
}

/// 棘轮会话状态。所有字段均可序列化/反序列化以持久化。
class ChatRatchetSession {
  /// 根密钥（DH 棘轮推进后更新）。
  final Uint8List rootKey;

  /// 发送链密钥；首次消息前为 null，由 X3DH 初始化。
  final Uint8List? sendingChainKey;

  /// 发送链上已用消息序号。
  final int sendingMessageNumber;

  /// 我方当前 DH 棘轮密钥对。
  final SimpleKeyPairData? sendingRatchetKey;

  /// 对端当前 DH 棘轮公钥。
  final SimplePublicKey? remoteRatchetKey;

  /// 上一发送链密钥（DH 棘轮换向时保留，供乱序消息的 skipped 恢复）。
  final Uint8List? previousSendingChainKey;

  /// 接收链密钥。
  final Uint8List? receivingChainKey;

  /// 接收链上已接收消息序号。
  final int receivingMessageNumber;

  /// 上次 DH 棘轮的 PN（对端发送链长度）。
  final int previousPn;

  /// 跳过的消息密钥：`"<remoteRatchetPubHex>:<n>" -> 32B 消息密钥`。
  final Map<String, Uint8List> skippedMessageKeys;

  const ChatRatchetSession({
    required this.rootKey,
    this.sendingChainKey,
    this.sendingMessageNumber = 0,
    this.sendingRatchetKey,
    this.remoteRatchetKey,
    this.previousSendingChainKey,
    this.receivingChainKey,
    this.receivingMessageNumber = 0,
    this.previousPn = 0,
    this.skippedMessageKeys = const {},
  });

  /// 序列化为 JSON（密钥以 hex 存储，供 SQLCipher 加密落库）。
  /// 异步：发送棘轮私钥需 extract。
  Future<Map<String, dynamic>> toJson() async {
    return {
        'root_key': hex.encode(rootKey),
        'sending_chain_key':
            sendingChainKey != null ? hex.encode(sendingChainKey!) : null,
        'sending_message_number': sendingMessageNumber,
        'sending_ratchet_private': sendingRatchetKey != null
            ? hex.encode(await ChatRatchet.exportPrivate(sendingRatchetKey!))
            : null,
        'sending_ratchet_public': sendingRatchetKey != null
            ? hex.encode(sendingRatchetKey!.publicKey.bytes)
            : null,
        'remote_ratchet_key':
            remoteRatchetKey != null ? hex.encode(remoteRatchetKey!.bytes) : null,
        'previous_sending_chain_key':
            previousSendingChainKey != null ? hex.encode(previousSendingChainKey!) : null,
        'receiving_chain_key':
            receivingChainKey != null ? hex.encode(receivingChainKey!) : null,
        'receiving_message_number': receivingMessageNumber,
        'previous_pn': previousPn,
        'skipped_message_keys': {
          for (final e in skippedMessageKeys.entries) e.key: hex.encode(e.value),
        },
      };
    }

  static ChatRatchetSession fromJson(Map<String, dynamic> json) {
    final skipped = <String, Uint8List>{};
    final rawSkipped = (json['skipped_message_keys'] as Map<String, dynamic>?) ?? {};
    rawSkipped.forEach((k, v) => skipped[k] = Uint8List.fromList(hex.decode(v as String)));

    final sendingRatchetKey = (json['sending_ratchet_private'] as String?) != null
        ? CryptoManager.restoreX25519KeyPair(
            privateKey: hex.decode(json['sending_ratchet_private'] as String),
            publicKey: hex.decode(json['sending_ratchet_public'] as String),
          )
        : null;

    return ChatRatchetSession(
      rootKey: Uint8List.fromList(hex.decode(json['root_key'] as String)),
      sendingChainKey: (json['sending_chain_key'] as String?) != null
          ? Uint8List.fromList(hex.decode(json['sending_chain_key'] as String))
          : null,
      sendingMessageNumber: json['sending_message_number'] as int,
      sendingRatchetKey: sendingRatchetKey,
      remoteRatchetKey: (json['remote_ratchet_key'] as String?) != null
          ? CryptoManager.keyFromHex(json['remote_ratchet_key'] as String)
          : null,
      previousSendingChainKey: (json['previous_sending_chain_key'] as String?) != null
          ? Uint8List.fromList(hex.decode(json['previous_sending_chain_key'] as String))
          : null,
      receivingChainKey: (json['receiving_chain_key'] as String?) != null
          ? Uint8List.fromList(hex.decode(json['receiving_chain_key'] as String))
          : null,
      receivingMessageNumber: json['receiving_message_number'] as int,
      previousPn: json['previous_pn'] as int,
      skippedMessageKeys: skipped,
    );
  }

  ChatRatchetSession copyWith({
    Uint8List? rootKey,
    Uint8List? sendingChainKey,
    bool clearSendingChainKey = false,
    int? sendingMessageNumber,
    SimpleKeyPairData? sendingRatchetKey,
    bool clearSendingRatchetKey = false,
    SimplePublicKey? remoteRatchetKey,
    Uint8List? previousSendingChainKey,
    bool clearPreviousSendingChainKey = false,
    Uint8List? receivingChainKey,
    bool clearReceivingChainKey = false,
    int? receivingMessageNumber,
    int? previousPn,
    Map<String, Uint8List>? skippedMessageKeys,
  }) {
    return ChatRatchetSession(
      rootKey: rootKey ?? this.rootKey,
      sendingChainKey: clearSendingChainKey
          ? null
          : (sendingChainKey ?? this.sendingChainKey),
      sendingMessageNumber: sendingMessageNumber ?? this.sendingMessageNumber,
      sendingRatchetKey: clearSendingRatchetKey
          ? null
          : (sendingRatchetKey ?? this.sendingRatchetKey),
      remoteRatchetKey: remoteRatchetKey ?? this.remoteRatchetKey,
      previousSendingChainKey: clearPreviousSendingChainKey
          ? null
          : (previousSendingChainKey ?? this.previousSendingChainKey),
      receivingChainKey: clearReceivingChainKey
          ? null
          : (receivingChainKey ?? this.receivingChainKey),
      receivingMessageNumber: receivingMessageNumber ?? this.receivingMessageNumber,
      previousPn: previousPn ?? this.previousPn,
      skippedMessageKeys: skippedMessageKeys ?? this.skippedMessageKeys,
    );
  }
}

/// 加密结果。
class ChatRatchetEncryptResult {
  final ChatRatchetSession session;
  final ChatEncryptedFrame frame;
  const ChatRatchetEncryptResult({required this.session, required this.frame});
}

/// 解密结果。
class ChatRatchetDecryptResult {
  final ChatRatchetSession session;
  final Uint8List plaintext;
  const ChatRatchetDecryptResult({required this.session, required this.plaintext});
}

/// 解密失败（MAC 校验不过 / 乱序跳过超上限）。链状态不回卷。
class ChatRatchetException implements Exception {
  final String message;
  const ChatRatchetException(this.message);
  @override
  String toString() => 'ChatRatchetException: $message';
}

class ChatRatchet {
  static const _infoRoot = 'MyPhone-Chat-Root-v1';
  static const _infoChain = 'MyPhone-Chat-ChainKey-v1';
  static const _infoMessage = 'MyPhone-Chat-MessageKey-v1';
  static const _nonceLength = 12;

  /// 计算绑定会话身份的 AAD（防跨会话/跨参与者重放）。
  static Uint8List associatedData({
    required String senderUserId,
    required String recipientUserId,
    required String conversationId,
  }) {
    return Uint8List.fromList(
      'MyPhone-Chat-v1:$senderUserId:$recipientUserId:$conversationId'.codeUnits,
    );
  }

  /// 初始化发起方会话：X3DH 之后，发起方用 DH(ourEph, theirSignedPrekey) 派生首条发送链。
  static Future<ChatRatchetSession> initiatorSession(
    Uint8List rootKey,
    SimpleKeyPairData ourRatchetKey,
    Uint8List firstChainKey,
  ) async {
    return ChatRatchetSession(
      rootKey: rootKey,
      sendingRatchetKey: ourRatchetKey,
      sendingChainKey: firstChainKey,
      remoteRatchetKey: null,
    );
  }

  /// 响应方初始会话。初始棘轮密钥应复用对端 signed-prekey 密钥对（标准 Signal 模型），
  /// 使首条发送链与发起方 `DH(ourRatchet, SPKb)` 对称。
  static Future<ChatRatchetSession> responderSession(
    Uint8List rootKey, {
    SimpleKeyPairData? ratchetKey,
  }) async {
    final x = X25519();
    final data = ratchetKey ?? await _toData(await x.newKeyPair());
    return ChatRatchetSession(rootKey: rootKey, sendingRatchetKey: data);
  }

  /// 加密一条消息。返回更新后的会话（必须持久化）。
  static Future<ChatRatchetEncryptResult> encrypt(
    ChatRatchetSession session,
    List<int> plaintext, {
    required List<int> aad,
  }) async {
    // 首次加密（发起方）：需已有 sendingChainKey（由 initiatorSession 提供）。
    var s = session;
    if (s.sendingChainKey == null) {
      final advanced = await _ratchetAdvanceForSend(s);
      s = advanced;
    }

    final chainKey = s.sendingChainKey!;
    final mk = await CryptoManager.hkdf(
      chainKey,
      _infoMessage,
      32,
      nonce: Uint8List.fromList(chainKey.sublist(0, 32)),
    );
    final nextChain = await CryptoManager.hkdf(
      chainKey,
      _infoChain,
      32,
      nonce: Uint8List.fromList(chainKey.sublist(0, 32)),
    );

    final nonce = CryptoManager.randomNonce12();
    final ciphertext = await CryptoManager.aesGcmEncrypt(
      plaintext,
      key: mk,
      nonce: nonce,
      aad: aad,
    );

    // 头部：{dh_pub, pn, n}。dh_pub 为我方当前棘轮公钥。
    final headerJson = jsonEncode({
      'dh_pub': hex.encode(s.sendingRatchetKey!.publicKey.bytes),
      'pn': s.previousPn,
      'n': s.sendingMessageNumber,
    });

    final newSession = s.copyWith(
      sendingChainKey: nextChain,
      sendingMessageNumber: s.sendingMessageNumber + 1,
    );

    return ChatRatchetEncryptResult(
      session: newSession,
      frame: ChatEncryptedFrame(
        header: Uint8List.fromList(utf8.encode(headerJson)),
        ciphertext: ciphertext,
      ),
    );
  }

  /// 解密一条消息。返回更新后的会话（必须持久化）。
  ///
  /// MAC 校验失败时抛出 [ChatRatchetException]，链状态不回卷。
  static Future<ChatRatchetDecryptResult> decrypt(
    ChatRatchetSession session,
    ChatEncryptedFrame frame, {
    required List<int> aad,
  }) async {
    final header = jsonDecode(utf8.decode(frame.header)) as Map<String, dynamic>;
    final theirDhPubHex = header['dh_pub'] as String;
    final theirPn = header['pn'] as int;
    final theirN = header['n'] as int;
    final theirDhPub = CryptoManager.keyFromHex(theirDhPubHex);

    var s = session;

    // 1) DH 棘轮推进：对端棘轮公钥变化 → 推进 root key。
    if (s.remoteRatchetKey == null ||
        !_pubKeyEquals(s.remoteRatchetKey!, theirDhPub)) {
      s = await _ratchetAdvanceForReceive(s, theirDhPub, theirPn);
    }

    // 2) 乱序恢复：从 skipped 表直接取消息密钥。
    final skipKey = '${theirDhPubHex}:${theirN}';
    Uint8List mk;
    var newSkipped = s.skippedMessageKeys;
    var receivingNumber = s.receivingMessageNumber;
    Uint8List? newReceivingChain = s.receivingChainKey;

    if (newSkipped.containsKey(skipKey)) {
      mk = newSkipped.remove(skipKey)!;
      newSkipped = Map<String, Uint8List>.from(newSkipped);
    } else if (theirN == s.receivingMessageNumber) {
      // 3) 正常按序解密。
      final chainKey = s.receivingChainKey!;
      mk = await CryptoManager.hkdf(
        chainKey,
        _infoMessage,
        32,
        nonce: Uint8List.fromList(chainKey.sublist(0, 32)),
      );
      newReceivingChain = await CryptoManager.hkdf(
        chainKey,
        _infoChain,
        32,
        nonce: Uint8List.fromList(chainKey.sublist(0, 32)),
      );
      receivingNumber = s.receivingMessageNumber + 1;
    } else {
      // 4) 跳过了若干条：先为中间序号暂存消息密钥，再解目标。
      if (theirN < s.receivingMessageNumber) {
        throw ChatRatchetException('duplicate or very old message');
      }
      if (theirN - s.receivingMessageNumber > kMaxSkippedMessageKeys) {
        throw ChatRatchetException('too many skipped message keys');
      }
      var chain = s.receivingChainKey!;
      for (var i = s.receivingMessageNumber; i < theirN; i++) {
        final k = await CryptoManager.hkdf(
          chain,
          _infoMessage,
          32,
          nonce: Uint8List.fromList(chain.sublist(0, 32)),
        );
        final next = await CryptoManager.hkdf(
          chain,
          _infoChain,
          32,
          nonce: Uint8List.fromList(chain.sublist(0, 32)),
        );
        newSkipped = Map<String, Uint8List>.from(newSkipped);
        newSkipped['${theirDhPubHex}:$i'] = k;
        if (newSkipped.length > kMaxSkippedMessageKeys) {
          throw ChatRatchetException('skipped message key storage full');
        }
        chain = next;
      }
      mk = await CryptoManager.hkdf(
        chain,
        _infoMessage,
        32,
        nonce: Uint8List.fromList(chain.sublist(0, 32)),
      );
      newReceivingChain = await CryptoManager.hkdf(
        chain,
        _infoChain,
        32,
        nonce: Uint8List.fromList(chain.sublist(0, 32)),
      );
      receivingNumber = theirN + 1;
    }

    // 5) AES-GCM 解密。失败 → 抛异常，链不回卷。
    final Uint8List plaintext;
    try {
      plaintext = await CryptoManager.aesGcmDecrypt(
        frame.ciphertext,
        key: mk,
        nonceLength: _nonceLength,
        aad: aad,
      );
    } catch (e) {
      throw ChatRatchetException('decrypt failed: $e');
    }

    final newSession = s.copyWith(
      receivingChainKey: newReceivingChain,
      receivingMessageNumber: receivingNumber,
      skippedMessageKeys: newSkipped,
    );

    return ChatRatchetDecryptResult(session: newSession, plaintext: plaintext);
  }

  /// 发送方向上的 DH 棘轮换向（发送链耗尽/首次回话时调用）。
  static Future<ChatRatchetSession> _ratchetAdvanceForSend(
    ChatRatchetSession s,
  ) async {
    final x = X25519();
    final ourNewRatchet = await x.newKeyPair();
    final ourNewRatchetData = await _toData(ourNewRatchet);

    if (s.remoteRatchetKey == null) {
      throw ChatRatchetException('cannot advance sending chain before receiving a message');
    }
    final dh = await x.sharedSecretKey(
      keyPair: ourNewRatchet,
      remotePublicKey: s.remoteRatchetKey!,
    );
    final dhBytes = await dh.extractBytes();
    final kdf = await CryptoManager.hkdf([...s.rootKey, ...dhBytes], _infoRoot, 64);
    final newRoot = Uint8List.sublistView(kdf, 0, 32);
    final newSendingChain = Uint8List.sublistView(kdf, 32, 64);

    return s.copyWith(
      rootKey: newRoot,
      sendingRatchetKey: ourNewRatchetData,
      sendingChainKey: newSendingChain,
      sendingMessageNumber: 0,
      previousSendingChainKey: s.sendingChainKey,
    );
  }

  /// 接收方向上的 DH 棘轮推进（标准 dh_ratchet，首次与换向统一）。
  static Future<ChatRatchetSession> _ratchetAdvanceForReceive(
    ChatRatchetSession s,
    SimplePublicKey theirDhPub,
    int theirPn,
  ) async {
    // 将旧接收链未消费的序号存入 skipped，供乱序消息恢复。
    var skipped = Map<String, Uint8List>.from(s.skippedMessageKeys);
    if (s.remoteRatchetKey != null && s.receivingChainKey != null) {
      var chain = s.receivingChainKey!;
      for (var i = s.receivingMessageNumber; i < s.previousPn; i++) {
        if (skipped.length > kMaxSkippedMessageKeys) {
          throw ChatRatchetException('skipped message key storage full');
        }
        final k = await CryptoManager.hkdf(
          chain,
          _infoMessage,
          32,
          nonce: Uint8List.fromList(chain.sublist(0, 32)),
        );
        skipped['${hex.encode(s.remoteRatchetKey!.bytes)}:$i'] = k;
        chain = await CryptoManager.hkdf(
          chain,
          _infoChain,
          32,
          nonce: Uint8List.fromList(chain.sublist(0, 32)),
        );
      }
    }

    // DH(ourSendingRatchet, theirNewDhPub) → 推进 root key。
    if (s.sendingRatchetKey == null) {
      throw ChatRatchetException('cannot receive without a ratchet key');
    }
    final x = X25519();
    final dh = await x.sharedSecretKey(
      keyPair: s.sendingRatchetKey!,
      remotePublicKey: theirDhPub,
    );
    final dhBytes = await dh.extractBytes();
    final kdf = await CryptoManager.hkdf([...s.rootKey, ...dhBytes], _infoRoot, 64);
    final newRoot = Uint8List.sublistView(kdf, 0, 32);
    final newReceivingChain = Uint8List.sublistView(kdf, 32, 64);

    // 换向：我方也推进棘轮密钥，用于后续发送。
    final x2 = X25519();
    final ourNewRatchet = await x2.newKeyPair();
    final ourNewRatchetData = await _toData(ourNewRatchet);
    final dh2 = await x2.sharedSecretKey(
      keyPair: ourNewRatchet,
      remotePublicKey: theirDhPub,
    );
    final dh2Bytes = await dh2.extractBytes();
    final sendKdf = await CryptoManager.hkdf([...newRoot, ...dh2Bytes], _infoRoot, 64);

    return ChatRatchetSession(
      rootKey: Uint8List.sublistView(sendKdf, 0, 32),
      sendingChainKey: Uint8List.sublistView(sendKdf, 32, 64),
      sendingMessageNumber: 0,
      sendingRatchetKey: ourNewRatchetData,
      remoteRatchetKey: theirDhPub,
      previousSendingChainKey: s.sendingChainKey,
      receivingChainKey: newReceivingChain,
      receivingMessageNumber: 0,
      previousPn: theirPn,
      skippedMessageKeys: skipped,
    );
  }

  static bool _pubKeyEquals(SimplePublicKey a, SimplePublicKey b) {
    if (a.bytes.length != b.bytes.length) return false;
    for (var i = 0; i < a.bytes.length; i++) {
      if (a.bytes[i] != b.bytes[i]) return false;
    }
    return true;
  }

  static Future<SimpleKeyPairData> _toData(SimpleKeyPair pair) async {
    final extracted = await pair.extract();
    return SimpleKeyPairData(
      Uint8List.fromList(await extracted.extractPrivateKeyBytes()),
      publicKey: extracted.publicKey,
      type: extracted.type,
    );
  }

  static Future<Uint8List> exportPrivate(SimpleKeyPairData data) async =>
      Uint8List.fromList(await data.extractPrivateKeyBytes());
}
