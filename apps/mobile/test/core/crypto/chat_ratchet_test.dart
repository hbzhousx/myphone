import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myphone/core/crypto/chat_ratchet.dart';
import 'package:myphone/core/crypto/crypto_manager.dart';

void main() {
  const alice = 'alice-user';
  const bob = 'bob-user';
  const convId = 'conv-1';

  List<int> ad(String sender, String recipient) => ChatRatchet.associatedData(
        senderUserId: sender,
        recipientUserId: recipient,
        conversationId: convId,
      );

  /// 构造一个双方共享的 root key（X3DH 一致性由 chat_session_manager 的测试覆盖，
  /// 此处聚焦双棘轮状态机本身）。
  Future<Uint8List> x3dhRoot() async => CryptoManager.randomBytes(32);

  /// 构造双向棘轮对。Alice 首链 = KDF_RK(root, DH(a_priv, B_pub))，Bob 首次接收
  /// 链 = KDF_RK(root, DH(b_priv, A_pub))（X25519 对称，二者相等）——模拟响应方复用
  /// signed-prekey 的标准 Signal 模型。
  Future<(ChatRatchetSession, ChatRatchetSession)> makePair(Uint8List root) async {
    final aRatchet = await CryptoManager.generateIdentityKeyPair();
    final bRatchet = await CryptoManager.generateIdentityKeyPair();
    final aExt = await aRatchet.extract();
    final bExt = await bRatchet.extract();
    final aData = CryptoManager.restoreX25519KeyPair(
      privateKey: await aExt.extractPrivateKeyBytes(),
      publicKey: aExt.publicKey.bytes,
    );
    final bData = CryptoManager.restoreX25519KeyPair(
      privateKey: await bExt.extractPrivateKeyBytes(),
      publicKey: bExt.publicKey.bytes,
    );

    final x = X25519();
    final dh = await x.sharedSecretKey(
      keyPair: aRatchet,
      remotePublicKey: bExt.publicKey,
    );
    final dhBytes = await dh.extractBytes();
    final kdf = await CryptoManager.hkdf(
      [...root, ...dhBytes],
      'MyPhone-Chat-Root-v1',
      64,
    );

    final aSession = await ChatRatchet.initiatorSession(
      Uint8List.fromList(kdf.sublist(0, 32)),
      aData,
      Uint8List.fromList(kdf.sublist(32, 64)),
    );
    final bSession = await ChatRatchet.responderSession(root, ratchetKey: bData);
    return (aSession, bSession);
  }

  group('ChatRatchet', () {
    test('initiator encrypt -> responder decrypt round trip', () async {
      final root = await x3dhRoot();
      final (aSession, bSession) = await makePair(root);

      final enc = await ChatRatchet.encrypt(aSession, utf8.encode('hello bob'), aad: ad(alice, bob));
      final dec = await ChatRatchet.decrypt(bSession, enc.frame, aad: ad(alice, bob));
      expect(utf8.decode(dec.plaintext), 'hello bob');
    });

    test('out-of-order delivery recovers all messages', () async {
      final root = await x3dhRoot();
      var (aSession, bSession) = await makePair(root);

      // 加密 5 条。
      final frames = <ChatEncryptedFrame>[];
      for (var i = 0; i < 5; i++) {
        final enc = await ChatRatchet.encrypt(aSession, utf8.encode('msg$i'), aad: ad(alice, bob));
        frames.add(enc.frame);
        aSession = enc.session;
      }

      // 乱序投递 5→1→4→2→3。
      final order = [4, 0, 3, 1, 2];
      final decrypted = <String>[];
      for (final idx in order) {
        final dec = await ChatRatchet.decrypt(bSession, frames[idx], aad: ad(alice, bob));
        decrypted.add(utf8.decode(dec.plaintext));
        bSession = dec.session;
      }
      expect(decrypted.toSet(), {'msg0', 'msg1', 'msg2', 'msg3', 'msg4'});
    });

    test('DH ratchet advances and both directions work across turns', () async {
      final root = await x3dhRoot();
      var (aSession, bSession) = await makePair(root);

      // 第 1 轮：alice 发。
      var enc = await ChatRatchet.encrypt(aSession, utf8.encode('a1'), aad: ad(alice, bob));
      var dec = await ChatRatchet.decrypt(bSession, enc.frame, aad: ad(alice, bob));
      bSession = dec.session;
      aSession = enc.session;
      expect(utf8.decode(dec.plaintext), 'a1');

      // 第 2 轮：bob 回（触发发送链换向 + DH 棘轮）。
      enc = await ChatRatchet.encrypt(bSession, utf8.encode('b1'), aad: ad(bob, alice));
      bSession = enc.session;
      dec = await ChatRatchet.decrypt(aSession, enc.frame, aad: ad(bob, alice));
      aSession = dec.session;
      expect(utf8.decode(dec.plaintext), 'b1');

      // 第 3 轮：alice 再发。
      enc = await ChatRatchet.encrypt(aSession, utf8.encode('a2'), aad: ad(alice, bob));
      aSession = enc.session;
      dec = await ChatRatchet.decrypt(bSession, enc.frame, aad: ad(alice, bob));
      bSession = dec.session;
      expect(utf8.decode(dec.plaintext), 'a2');

      // 第 4 轮：bob 再回。
      enc = await ChatRatchet.encrypt(bSession, utf8.encode('b2'), aad: ad(bob, alice));
      dec = await ChatRatchet.decrypt(aSession, enc.frame, aad: ad(bob, alice));
      expect(utf8.decode(dec.plaintext), 'b2');
    });

    test('tampered ciphertext fails and chain does not advance', () async {
      final root = await x3dhRoot();
      var (aSession, bSession) = await makePair(root);

      final enc = await ChatRatchet.encrypt(aSession, utf8.encode('secret'), aad: ad(alice, bob));
      aSession = enc.session;

      // 篡改密文一个字节。
      final tampered = Uint8List.fromList(enc.frame.ciphertext);
      tampered[10] ^= 0x01;
      final tamperedFrame = ChatEncryptedFrame(header: enc.frame.header, ciphertext: tampered);

      expect(
        () => ChatRatchet.decrypt(bSession, tamperedFrame, aad: ad(alice, bob)),
        throwsA(isA<ChatRatchetException>()),
      );

      // 链不回卷：篡改后继续解真实消息应成功。
      final enc2 = await ChatRatchet.encrypt(aSession, utf8.encode('second'), aad: ad(alice, bob));
      final dec = await ChatRatchet.decrypt(bSession, enc2.frame, aad: ad(alice, bob));
      expect(utf8.decode(dec.plaintext), 'second');
    });

    test('nonce is cryptographically random (1000 distinct)', () async {
      final root = await x3dhRoot();
      final (aSession, _) = await makePair(root);
      var session = aSession;

      final nonces = <String>{};
      for (var i = 0; i < 1000; i++) {
        final enc = await ChatRatchet.encrypt(session, utf8.encode('x'), aad: ad(alice, bob));
        session = enc.session;
        nonces.add(enc.frame.ciphertext.sublist(0, 12).toString());
      }
      expect(nonces.length, 1000);
    });

    test('AAD binding rejects decryption under different conversation', () async {
      final root = await x3dhRoot();
      final (aSession, bSession) = await makePair(root);

      final enc = await ChatRatchet.encrypt(aSession, utf8.encode('hi'), aad: ad(alice, bob));
      // 用错误的会话/参与者 AAD 解密 → 失败。
      expect(
        () => ChatRatchet.decrypt(
          bSession,
          enc.frame,
          aad: ad(alice, 'mallory'),
        ),
        throwsA(isA<ChatRatchetException>()),
      );
    });

    test('session serialize -> restore -> continue ratchet', () async {
      final root = await x3dhRoot();
      var (aSession, bSession) = await makePair(root);

      // alice 发两条，序列化后恢复。
      var enc = await ChatRatchet.encrypt(aSession, utf8.encode('m1'), aad: ad(alice, bob));
      aSession = enc.session;
      enc = await ChatRatchet.encrypt(aSession, utf8.encode('m2'), aad: ad(alice, bob));
      aSession = enc.session;

      final restored = ChatRatchetSession.fromJson(await aSession.toJson());
      expect(restored.sendingMessageNumber, aSession.sendingMessageNumber);
      expect(restored.rootKey, orderedEquals(aSession.rootKey));

      // 恢复后的会话继续加密，bob 可解。
      var d1 = await ChatRatchet.decrypt(bSession, enc.frame, aad: ad(alice, bob));
      bSession = d1.session;
      final enc3 = await ChatRatchet.encrypt(restored, utf8.encode('m3'), aad: ad(alice, bob));
      final d3 = await ChatRatchet.decrypt(bSession, enc3.frame, aad: ad(alice, bob));
      expect(utf8.decode(d3.plaintext), 'm3');
    });

    test('frame bytes round trip', () async {
      final root = await x3dhRoot();
      final (aSession, bSession) = await makePair(root);

      final enc = await ChatRatchet.encrypt(aSession, utf8.encode('bytes'), aad: ad(alice, bob));
      final wire = enc.frame.toBytes();
      final parsed = ChatEncryptedFrame.fromBytes(wire);
      expect(parsed.header, orderedEquals(enc.frame.header));
      expect(parsed.ciphertext, orderedEquals(enc.frame.ciphertext));

      final dec = await ChatRatchet.decrypt(bSession, parsed, aad: ad(alice, bob));
      expect(utf8.decode(dec.plaintext), 'bytes');
    });
  });
}
