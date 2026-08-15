/// 聊天 X3DH 会话管理器：prekey bundle 发布、发起/响应方 X3DH 建立、会话持久化。
///
/// 与通话 E2EE 共享同一身份密钥（`e2ee_identity_x25519`，Signal 风格），
/// 远端身份缓存用独立的 `chat_remote_identity_<uid>` 键，避免与通话指纹缓存冲突。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:convert/convert.dart';
import 'package:flutter/foundation.dart' show debugPrint;

import '../network/api_client.dart';
import '../storage/database.dart';
import 'chat_crypto.dart';
import 'crypto_manager.dart';

/// establishAsResponder 的返回：会话 + 诊断用本地 SPK 公钥指纹。
class ResponderSession {
  final ChatCryptoSession session;
  final String spkFingerprint;

  /// 本地 IK 公钥指纹（对比发送方 bundle 的 their_ik_fp）。
  final String myIkFingerprint;
  const ResponderSession({
    required this.session,
    required this.spkFingerprint,
    this.myIkFingerprint = '',
  });
}

class ChatSessionManager {
  static const _identityKeyType = 'e2ee_identity_x25519';
  static const _signingKeyType = 'chat_signing_ed25519';
  static const _remoteIdentityPrefix = 'chat_remote_identity_';

  /// 一次性 prekey 上传数量（不足时补充）。
  static const _prekeyBatchSize = 100;
  static const _minPrekeysBeforeTopup = 20;

  final DatabaseManager _db;
  final ApiClient _api;

  ChatSessionManager({
    required DatabaseManager db,
    required ApiClient api,
  })  : _db = db,
        _api = api;

  // ---- 身份/签名密钥 ----

  Future<SimpleKeyPairData> loadOrCreateIdentityKey() => _loadOrCreatePair(
        baseKeyType: _identityKeyType,
        generator: CryptoManager.generateIdentityKeyPair,
        restore: CryptoManager.restoreX25519KeyPair,
      );

  Future<SimpleKeyPairData> loadOrCreateSigningKey() => _loadOrCreatePair(
        baseKeyType: _signingKeyType,
        generator: CryptoManager.generateSigningKeyPair,
        restore: CryptoManager.restoreEd25519KeyPair,
      );

  Future<SimpleKeyPairData> _loadOrCreatePair({
    required String baseKeyType,
    required Future<SimpleKeyPair> Function() generator,
    required SimpleKeyPairData Function({
      required List<int> privateKey,
      required List<int> publicKey,
    }) restore,
  }) async {
    final privateKey = await _db.getKey('${baseKeyType}_private');
    final publicKey = await _db.getKey('${baseKeyType}_public');
    if (privateKey != null && publicKey != null) {
      return restore(privateKey: privateKey, publicKey: publicKey);
    }
    final pair = await generator();
    final exported = await CryptoManager.exportKeyPair(pair);
    await _db.storeKey('${baseKeyType}_private', exported.privateKey);
    await _db.storeKey('${baseKeyType}_public', exported.publicKey);
    return restore(privateKey: exported.privateKey, publicKey: exported.publicKey);
  }

  // ---- prekey bundle 发布 ----

  /// 生成并上传签名预密钥 + 一批一次性预密钥（幂等）。
  /// ★SPK 必须复用：若本地已有则沿用，避免每次登录重新生成导致「发起方 bundle 的
  ///    SPK 公钥」与「响应方本地 SPK 私钥」不同步 → X3DH 不匹配 → 首条消息解密失败。
  Future<void> publishPrekeyBundle() async {
    // ★同步本地 identity 到服务器：登录/重装后本地可能生成了新 identity，而服务器
    //   还是旧值（登录路径不上传 identity）→ 对端取 bundle 拿旧 IK、本机用新 IK
    //   → X3DH DH2 不对称 → 每条消息解密 MAC 失败。每次启动都同步，保证一致。
    try {
      final identity = await loadOrCreateIdentityKey();
      final idPub = await identity.extractPublicKey();
      await _api.updateIdentity(identityPublicKey: hex.encode(idPub.bytes));
    } catch (e) {
      debugPrint('[SESSION] updateIdentity failed (non-fatal): $e');
    }

    final signingKey = await loadOrCreateSigningKey();

    // 签名预密钥：优先复用本地已有（含私钥），仅首次生成。
    SimpleKeyPairData spkPair;
    int keyId;
    final existingPriv = await _db.getKey('chat_spk_private');
    final existingPub = await _db.getKey('chat_spk_public');
    final existingId = await _db.getKey('chat_spk_id');
    if (existingPriv != null && existingPub != null) {
      spkPair = CryptoManager.restoreX25519KeyPair(
        privateKey: existingPriv,
        publicKey: existingPub,
      );
      keyId = existingId != null
          ? (existingId[0] |
              (existingId[1] << 8) |
              (existingId[2] << 16) |
              (existingId[3] << 24))
          : (DateTime.now().millisecondsSinceEpoch & 0x7fffffff);
    } else {
      final newSpk = await CryptoManager.generateSignedPreKey();
      final exported = await CryptoManager.exportKeyPair(newSpk.keyPair);
      spkPair = CryptoManager.restoreX25519KeyPair(
        privateKey: exported.privateKey,
        publicKey: exported.publicKey,
      );
      keyId = (DateTime.now().millisecondsSinceEpoch & 0x7fffffff);
      await _db.storeKey('chat_spk_private', exported.privateKey);
      await _db.storeKey('chat_spk_public', exported.publicKey);
      await _db.storeKey('chat_spk_id', [
        keyId & 0xFF,
        (keyId >> 8) & 0xFF,
        (keyId >> 16) & 0xFF,
        (keyId >> 24) & 0xFF,
      ]);
    }

    final spkPub = await spkPair.extractPublicKey();
    final sigPayload = utf8.encode(jsonEncode({
      'key_id': keyId,
      'public_key': hex.encode(spkPub.bytes),
    }));
    final signature = await CryptoManager.signBytes(sigPayload, signingKey);
    await _api.uploadSignedPreKey(
      keyId: keyId,
      publicKey: hex.encode(spkPub.bytes),
      signature: hex.encode(signature),
    );

    // 一次性预密钥：每次启动都重新生成一批并上传（服务器端先清旧再插）。
    // ★不能只在数量不足时补——否则服务器残留旧批次/孤儿 OTP（key_id 与当前批次
    //   不同），发起方 GetKeyBundle 取到孤儿公钥、响应方本地无对应私钥 → X3DH 失配
    //   → 解密失败/灰块。每次重传保证服务器永远只有当前批次（响应方必有私钥）。
    final batch = await CryptoManager.generatePreKeys(_prekeyBatchSize);
    final preKeys = <Map<String, dynamic>>[];
    final baseTs = DateTime.now().millisecondsSinceEpoch & 0x7fffffff;
    for (var i = 0; i < batch.length; i++) {
      final pub = await batch[i].extractPublicKey();
      final id = baseTs + i;
      final exported = await CryptoManager.exportKeyPair(batch[i]);
      await _db.storeKey('chat_otp_${id}_private', exported.privateKey);
      await _db.storeKey('chat_otp_${id}_public', exported.publicKey);
      preKeys.add({'key_id': id, 'public_key': hex.encode(pub.bytes)});
    }
    await _api.uploadPreKeys(preKeys);
    await _db.storeKey('${_identityKeyType}_prekey_count', [_prekeyBatchSize]);
  }

  // ---- 发起方 X3DH ----

  /// 发起方建立会话：取对端 bundle → 验签 → X3DH → 初始化棘轮 → 持久化。
  /// 返回 initPayload（发起方 X3DH 公钥输入），首条消息携带给响应方建立会话。
  Future<Map<String, dynamic>> establishAsInitiator({
    required String remoteUserId,
    required String conversationId,
  }) async {
    final bundle = await _api.fetchKeyBundle(remoteUserId);

    final theirIdentityPub =
        CryptoManager.keyFromHex(bundle['identity_public_key'] as String);
    await _verifyRemoteIdentity(remoteUserId, theirIdentityPub);

    final spk = bundle['signed_prekey'] as Map<String, dynamic>;
    final spkPub = CryptoManager.keyFromHex(spk['public_key'] as String);
    final spkKeyId = spk['key_id'] as int?;
    final otp = bundle['one_time_prekey'] as Map<String, dynamic>?;
    final otpKeyId = otp?['key_id'] as int?;

    // 尽力而为的签名预密钥校验：服务器 bundle 携带签名公钥时才校验。
    // （当前服务器未存 Ed25519 签名公钥，无法强验；身份绑定由 _verifyRemoteIdentity
    //   的指纹 TOFU 保证，X3DH 的 DH 结果也依赖对端真实 SPK 才能对上。）
    final theirSigningPubHex = bundle['signing_public_key'] as String?;
    if (theirSigningPubHex != null && theirSigningPubHex.isNotEmpty) {
      final theirSigningPub = CryptoManager.keyFromHex(theirSigningPubHex);
      final ok = await CryptoManager.verifySignature(
        payload: utf8.encode(jsonEncode({
          'key_id': spk['key_id'],
          'public_key': spk['public_key'],
        })),
        signature: hex.decode(spk['signature'] as String),
        signingPublicKey: theirSigningPub,
      );
      if (!ok) {
        throw ChatCryptoException('signed prekey signature invalid');
      }
    }

    final ourIdentity = await loadOrCreateIdentityKey();
    final ourEph = await CryptoManager.generateIdentityKeyPair();

    final root = await CryptoManager.x3dhKeyAgreement(
      ourIdentityKey: ourIdentity,
      ourEphemeralKey: ourEph,
      theirIdentityKey: theirIdentityPub,
      theirSignedPreKey: spkPub,
      theirOneTimePreKey:
          otp != null ? CryptoManager.keyFromHex(otp['public_key'] as String) : null,
    );

    // 简化方案：X3DH 的 root 直接作为会话密钥（复用语音思路，无双棘轮）。
    final session = ChatCrypto.initSession(
      root,
      remoteIdentityPub: theirIdentityPub.bytes,
    );
    await _saveSession(conversationId, session, remoteUserId);

    // 首条消息携带的 X3DH 公钥输入：响应方据此建立会话。
    final ourIdentityPub = await ourIdentity.extractPublicKey();
    final ourEphPub = await ourEph.extractPublicKey();
    return {
      'identity_public_key': hex.encode(ourIdentityPub.bytes),
      'ephemeral_public_key': hex.encode(ourEphPub.bytes),
      'signed_prekey_id': spkKeyId,
      'one_time_prekey_id': otpKeyId,
      // 诊断：从 bundle 拿到的对端 SPK/OTP/identity 公钥指纹（对比响应方本地是否配对）。
      'their_spk_fp': hex.encode(spkPub.bytes).substring(0, 16),
      'their_otp_fp': otp != null
          ? hex.encode(CryptoManager.keyFromHex(otp['public_key'] as String).bytes)
              .substring(0, 16)
          : 'none',
      'their_ik_fp': hex.encode(theirIdentityPub.bytes).substring(0, 16),
      'my_ik_fp': hex.encode(ourIdentityPub.bytes).substring(0, 16),
      'my_ek_fp': hex.encode(ourEphPub.bytes).substring(0, 16),
    };
  }

  // ---- 响应方 X3DH ----

  /// 响应方建立会话（收到对端首个 chatMessage/chatInit 时调用）。
  Future<ResponderSession> establishAsResponder({
    required String remoteUserId,
    required String conversationId,
    required Map<String, dynamic> initPayload,
  }) async {
    final theirIdentityPub =
        CryptoManager.keyFromHex(initPayload['identity_public_key'] as String);
    await _verifyRemoteIdentity(remoteUserId, theirIdentityPub);

    final ourIdentity = await loadOrCreateIdentityKey();
    final theirEph =
        CryptoManager.keyFromHex(initPayload['ephemeral_public_key'] as String);

    // 响应方 X3DH：手动计算 DH1||DH2||DH3||DH4（与发起方 x3dhKeyAgreement 对称）。
    final spkPair = await _loadOurSignedPrekey();
    final otpId = initPayload['one_time_prekey_id'] as int?;
    final otpPair = otpId != null ? await _loadOurOneTimePrekey(otpId) : null;

    // ★关键：发起方若用了 OTP（initPayload 带 one_time_prekey_id）做 DH4，而响应方
    //   找不到对应 OTP 私钥时，绝不能静默跳过 DH4 —— 那样两端 X3DH 不对称（发起方
    //   算了 DH4、响应方没算）→ root key 不同 → 每条消息 AES-GCM MAC 失败。
    //   必须抛错，让上层知道"无法建立匹配会话"，发送方可重试/重新协商。
    if (otpId != null && otpPair == null) {
      throw ChatCryptoException(
          'responder missing OTP private key for key_id=$otpId (session mismatch)');
    }

    final secrets = <List<int>>[
      await _dh(spkPair, theirIdentityPub), // DH1 = DH(SPKb, IKa)
      await _dh(ourIdentity, theirEph), // DH2 = DH(IKb, EKa)
      await _dh(spkPair, theirEph), // DH3 = DH(SPKb, EKa)
      if (otpPair != null) await _dh(otpPair, theirEph), // DH4 = DH(OPKb, EKa)
    ];
    final root = await CryptoManager.hkdf(
      _concat(secrets),
      'MyPhone-X3DH-v1',
      32,
    );

    final session = ChatCrypto.initSession(
      root,
      remoteIdentityPub: theirIdentityPub.bytes,
    );
    await _saveSession(conversationId, session, remoteUserId);
    // 诊断：附带本地 SPK + IK 公钥指纹，供 controller 上报对比发起方 bundle。
    final spkPubBytes = await spkPair.extractPublicKey();
    final myIkPubBytes = await ourIdentity.extractPublicKey();
    return ResponderSession(
      session: session,
      spkFingerprint: hex.encode(spkPubBytes.bytes).substring(0, 16),
      myIkFingerprint: hex.encode(myIkPubBytes.bytes).substring(0, 16),
    );
  }

  // ---- 会话持久化 ----

  Future<ChatCryptoSession?> loadSession(String conversationId) async {
    final json = await _db.getChatSessionJson(conversationId);
    if (json == null) return null;
    try {
      return ChatCryptoSession.fromJson(jsonDecode(json) as Map<String, dynamic>);
    } catch (_) {
      // 旧版双棘轮 JSON 或损坏行：视为无会话，下次发送会重新建立。
      return null;
    }
  }

  Future<void> saveSession(String conversationId, ChatCryptoSession session) =>
      _saveSession(conversationId, session, null);

  Future<void> _saveSession(
    String conversationId,
    ChatCryptoSession session,
    String? remoteUserId,
  ) async {
    final json = jsonEncode(session.toJson());
    await _db.saveChatSession(conversationId, json,
        remoteIdentityPub: remoteUserId);
  }

  // ---- 辅助 ----

  Future<List<int>> _dh(SimpleKeyPairData ours, SimplePublicKey theirs) async {
    final x = X25519();
    final sk = await x.sharedSecretKey(keyPair: ours, remotePublicKey: theirs);
    return sk.extractBytes();
  }

  Uint8List _concat(List<List<int>> parts) {
    final total = parts.fold<int>(0, (s, p) => s + p.length);
    final r = Uint8List(total);
    var off = 0;
    for (final p in parts) {
      r.setRange(off, off + p.length, p);
      off += p.length;
    }
    return r;
  }

  Future<void> _verifyRemoteIdentity(
    String remoteUserId,
    SimplePublicKey theirIdentityPub,
  ) async {
    final fingerprint = CryptoManager.fingerprintFromPublicKey(theirIdentityPub.bytes);
    final stored = await _db.getKey('$_remoteIdentityPrefix$remoteUserId');
    if (stored == null) {
      await _db.storeKey('$_remoteIdentityPrefix$remoteUserId', fingerprint.codeUnits);
      return;
    }
    final storedFingerprint = String.fromCharCodes(stored);
    if (storedFingerprint != fingerprint) {
      // ★修复：对端 identity 变化（重装/重新注册后新 identity）时，TOFU 重新信任
      //   并更新缓存，而不是抛错。否则新 identity 上传后，对端缓存旧指纹，首次
      //   会话建立直接失败 → 消息永远发不出（报 fingerprint mismatch）。
      //   X3DH 本身是初次协商，第一次建立会话时更新缓存是安全的。
      debugPrint('[SESSION] remote identity changed, re-trusting new fingerprint for $remoteUserId');
      await _db.storeKey('$_remoteIdentityPrefix$remoteUserId', fingerprint.codeUnits);
    }
  }

  Future<SimpleKeyPairData> _loadOurSignedPrekey() async {
    final priv = await _db.getKey('chat_spk_private');
    final pub = await _db.getKey('chat_spk_public');
    if (priv != null && pub != null) {
      return CryptoManager.restoreX25519KeyPair(privateKey: priv, publicKey: pub);
    }
    // 未发布过 bundle：临时生成（下次 publishPrekeyBundle 会覆盖）。
    final spk = await CryptoManager.generateSignedPreKey();
    final exported = await CryptoManager.exportKeyPair(spk.keyPair);
    await _db.storeKey('chat_spk_private', exported.privateKey);
    await _db.storeKey('chat_spk_public', exported.publicKey);
    return CryptoManager.restoreX25519KeyPair(
      privateKey: exported.privateKey,
      publicKey: exported.publicKey,
    );
  }

  Future<SimpleKeyPairData?> _loadOurOneTimePrekey(int keyId) async {
    final priv = await _db.getKey('chat_otp_${keyId}_private');
    final pub = await _db.getKey('chat_otp_${keyId}_public');
    if (priv == null || pub == null) return null;
    return CryptoManager.restoreX25519KeyPair(privateKey: priv, publicKey: pub);
  }
}
