/// 聊天 X3DH 会话管理器：prekey bundle 发布、发起/响应方 X3DH 建立、会话持久化。
///
/// 与通话 E2EE 共享同一身份密钥（`e2ee_identity_x25519`，Signal 风格），
/// 远端身份缓存用独立的 `chat_remote_identity_<uid>` 键，避免与通话指纹缓存冲突。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:convert/convert.dart';

import '../network/api_client.dart';
import '../storage/database.dart';
import 'chat_crypto.dart';
import 'crypto_manager.dart';

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

    // 一次性预密钥（不足即补传，幂等）。
    final countRow = await _db.getKey('${_identityKeyType}_prekey_count');
    final have = countRow != null ? countRow.first : 0;
    if (have < _minPrekeysBeforeTopup) {
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
    };
  }

  // ---- 响应方 X3DH ----

  /// 响应方建立会话（收到对端首个 chatMessage/chatInit 时调用）。
  Future<ChatCryptoSession> establishAsResponder({
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
    return session;
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
      throw ChatCryptoException('remote identity changed — fingerprint mismatch');
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
