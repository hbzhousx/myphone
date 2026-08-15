import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as cryptography;
import 'package:flutter_test/flutter_test.dart';
import 'package:myphone/core/crypto/chat_crypto.dart';
import 'package:myphone/core/crypto/crypto_manager.dart';

/// 响应方 X3DH：手动 DH1||DH2||DH3||DH4（与 establishAsResponder 相同算法）。
Future<Uint8List> _responderX3dh({
  required cryptography.SimpleKeyPair ourIdentity,
  required cryptography.SimpleKeyPair ourSpk,
  required cryptography.SimpleKeyPair ourOtp,
  required cryptography.SimplePublicKey theirIdentityPub,
  required cryptography.SimplePublicKey theirEphPub,
}) async {
  final x = cryptography.X25519();
  Future<List<int>> dh(
      cryptography.SimpleKeyPair ours, cryptography.SimplePublicKey theirs) async {
    final sk = await x.sharedSecretKey(keyPair: ours, remotePublicKey: theirs);
    return await sk.extractBytes();
  }
  final secrets = <List<int>>[
    await dh(ourSpk, theirIdentityPub), // DH1 = DH(SPKb, IKa)
    await dh(ourIdentity, theirEphPub), // DH2 = DH(IKb, EKa)
    await dh(ourSpk, theirEphPub), // DH3 = DH(SPKb, EKa)
    await dh(ourOtp, theirEphPub), // DH4 = DH(OPKb, EKa)
  ];
  final concat = Uint8List(secrets.fold<int>(0, (s, p) => s + p.length));
  var off = 0;
  for (final part in secrets) {
    concat.setRange(off, off + part.length, part);
    off += part.length;
  }
  return CryptoManager.hkdf(concat, 'MyPhone-X3DH-v1', 32);
}

void main() {
  const alice = 'alice-user';
  const bob = 'bob-user';
  const convId = 'conv-1';

  List<int> ad(String sender, String recipient) => ChatCrypto.associatedData(
        senderUserId: sender,
        recipientUserId: recipient,
        conversationId: convId,
      );

  /// 构造双方共享会话（同一 sessionKey）。
  (ChatCryptoSession, ChatCryptoSession) makePair() {
    final key = CryptoManager.randomBytes(32);
    final a = ChatCrypto.initSession(key, remoteIdentityPub: [1, 2, 3]);
    final b = ChatCrypto.initSession(key, remoteIdentityPub: [1, 2, 3]);
    return (a, b);
  }

  group('ChatCrypto', () {
    test('round trip: A encrypt -> B decrypt', () async {
      final (a, b) = makePair();
      final enc = await ChatCrypto.encryptMessage(
          a, utf8.encode('hello bob'), messageId: 'm1', aad: ad(alice, bob));
      expect(enc.counter, 1);
      expect(enc.session.sendCounter, 2);

      final dec = await ChatCrypto.decryptMessage(b, enc.ciphertext,
          messageId: 'm1', counter: enc.counter, aad: ad(alice, bob));
      expect(utf8.decode(dec.plaintext), 'hello bob');
      expect(dec.session.recvCounter, 1);
    });

    test('bidirectional independence', () async {
      final (a, b) = makePair();
      final aEnc = await ChatCrypto.encryptMessage(
          a, utf8.encode('a1'), messageId: 'a1', aad: ad(alice, bob));
      await ChatCrypto.decryptMessage(b, aEnc.ciphertext,
          messageId: 'a1', counter: aEnc.counter, aad: ad(alice, bob));
      // B -> A (B 的发送 counter 独立于 A 的接收 counter)
      final bEnc = await ChatCrypto.encryptMessage(
          b, utf8.encode('b1'), messageId: 'b1', aad: ad(bob, alice));
      expect(bEnc.counter, 1);
      final dec = await ChatCrypto.decryptMessage(a, bEnc.ciphertext,
          messageId: 'b1', counter: bEnc.counter, aad: ad(bob, alice));
      expect(utf8.decode(dec.plaintext), 'b1');
      expect(dec.session.recvCounter, 1);
    });

    test('sequential multi-message advances counters', () async {
      final (a, b) = makePair();
      var sendSession = a;
      var recvSession = b;
      for (var i = 1; i <= 5; i++) {
        final enc = await ChatCrypto.encryptMessage(sendSession,
            utf8.encode('m$i'), messageId: 'm$i', aad: ad(alice, bob));
        expect(enc.counter, i);
        sendSession = enc.session;
        final dec = await ChatCrypto.decryptMessage(recvSession, enc.ciphertext,
            messageId: 'm$i', counter: enc.counter, aad: ad(alice, bob));
        recvSession = dec.session;
        expect(utf8.decode(dec.plaintext), 'm$i');
      }
      expect(recvSession.recvCounter, 5);
      expect(sendSession.sendCounter, 6);
    });

    test('replay rejection', () async {
      final (a, b) = makePair();
      final enc = await ChatCrypto.encryptMessage(
          a, utf8.encode('once'), messageId: 'm1', aad: ad(alice, bob));
      final dec = await ChatCrypto.decryptMessage(b, enc.ciphertext,
          messageId: 'm1', counter: enc.counter, aad: ad(alice, bob));
      await expectLater(
        ChatCrypto.decryptMessage(dec.session, enc.ciphertext,
            messageId: 'm1', counter: enc.counter, aad: ad(alice, bob)),
        throwsA(isA<ChatCryptoException>()),
      );
    });

    test('out-of-order delivery tolerated', () async {
      final (a, b) = makePair();
      // 用同一发送会话连发 3 条，counter 应为 1,2,3。
      var send = a;
      final msgs = <(Uint8List, int, String)>[];
      for (var i = 1; i <= 3; i++) {
        final enc = await ChatCrypto.encryptMessage(send, utf8.encode('m$i'),
            messageId: 'm$i', aad: ad(alice, bob));
        send = enc.session;
        msgs.add((enc.ciphertext, enc.counter, 'm$i'));
      }
      expect(msgs.map((m) => m.$2).toList(), [1, 2, 3]);
      // 乱序投递：1, 3, 2。
      var session = b;
      for (final idx in [0, 2, 1]) {
        final dec = await ChatCrypto.decryptMessage(session, msgs[idx].$1,
            messageId: msgs[idx].$3,
            counter: msgs[idx].$2,
            aad: ad(alice, bob));
        session = dec.session;
      }
      expect(session.recvCounter, 3);
    });

    test('gap beyond window rejected', () async {
      final (a, b) = makePair();
      // 发送会话的 counter 推到 200（模拟对端已发 199 条）。
      final farSender = a.copyWith(sendCounter: 200);
      final enc = await ChatCrypto.encryptMessage(farSender,
          utf8.encode('far'), messageId: 'm200', aad: ad(alice, bob));
      expect(enc.counter, 200);
      // 接收方 recvCounter=0，counter 200 > 0+100 → 拒绝。
      await expectLater(
        ChatCrypto.decryptMessage(b, enc.ciphertext,
            messageId: 'm200', counter: enc.counter, aad: ad(alice, bob)),
        throwsA(isA<ChatCryptoException>()),
      );
    });

    test('tampered ciphertext fails, session not advanced', () async {
      final (a, b) = makePair();
      final enc = await ChatCrypto.encryptMessage(
          a, utf8.encode('secret'), messageId: 'm1', aad: ad(alice, bob));
      final tampered = Uint8List.fromList(enc.ciphertext)..[10] ^= 0x01;
      await expectLater(
        ChatCrypto.decryptMessage(b, tampered,
            messageId: 'm1', counter: enc.counter, aad: ad(alice, bob)),
        throwsA(isA<ChatCryptoException>()),
      );
      // 会话不回卷：后续真实消息仍可解。
      final enc2 = await ChatCrypto.encryptMessage(
          a, utf8.encode('second'), messageId: 'm2', aad: ad(alice, bob));
      final dec = await ChatCrypto.decryptMessage(b, enc2.ciphertext,
          messageId: 'm2', counter: enc2.counter, aad: ad(alice, bob));
      expect(utf8.decode(dec.plaintext), 'second');
    });

    test('AAD binding rejects wrong conversation', () async {
      final (a, b) = makePair();
      final enc = await ChatCrypto.encryptMessage(
          a, utf8.encode('hi'), messageId: 'm1', aad: ad(alice, bob));
      await expectLater(
        ChatCrypto.decryptMessage(b, enc.ciphertext,
            messageId: 'm1', counter: enc.counter, aad: ad(alice, 'mallory')),
        throwsA(isA<ChatCryptoException>()),
      );
    });

    test('symmetric AAD across per-side conversationId (real-device regression)',
        () async {
      // 真机复现：发送方 conversationId = conv-<对端>，接收方 = conv-<对端>，
      // 两端 convId 不同（发送方 conv-bob、接收方 conv-alice）。修复前
      // associatedData 把 convId 拼进 AAD → 两端 AAD 不同 → MAC 失败。
      // 修复后 AAD 只含排序后的双方 id，两端一致。
      final (a, b) = makePair();
      final senderAad = ChatCrypto.associatedData(
        senderUserId: alice,
        recipientUserId: bob,
        conversationId: 'conv-bob', // 发送方视角：conv-<对端bob>
      );
      final receiverAad = ChatCrypto.associatedData(
        senderUserId: bob, // 接收方视角：sender 是 bob
        recipientUserId: alice,
        conversationId: 'conv-alice', // 接收方视角：conv-<对端alice>
      );
      expect(senderAad, receiverAad, reason: '两端 AAD 必须一致');

      final enc = await ChatCrypto.encryptMessage(
          a, utf8.encode('hi'), messageId: 'm1', aad: senderAad);
      final dec = await ChatCrypto.decryptMessage(b, enc.ciphertext,
          messageId: 'm1', counter: enc.counter, aad: receiverAad);
      expect(utf8.decode(dec.plaintext), 'hi');
    });

    test('X3DH negotiation produces matching session keys on both sides',
        () async {
      // 模拟真实两端 X3DH：发起方取对端 bundle → x3dhKeyAgreement；
      // 响应方用 init_payload → 手动 DH1||DH2||DH3||DH4。
      // 验证两端 sessionKey 一致、能加解密。
      final x = cryptography.X25519();

      // Bob（响应方）生成身份/SPK/OTP
      final bobIdentity = await CryptoManager.generateIdentityKeyPair();
      final bobSpk = await CryptoManager.generateSignedPreKey();
      final bobOtps = await CryptoManager.generatePreKeys(1);
      final bobOtp = bobOtps.first;

      // Alice（发起方）取 Bob bundle 公钥
      final bobIdentityPub = await bobIdentity.extractPublicKey();
      final bobSpkPub = await bobSpk.keyPair.extractPublicKey();
      final bobOtpPub = await bobOtp.extractPublicKey();

      // 发起方 X3DH
      final aliceIdentity = await CryptoManager.generateIdentityKeyPair();
      final aliceEph = await CryptoManager.generateIdentityKeyPair();
      final aliceRoot = await CryptoManager.x3dhKeyAgreement(
        ourIdentityKey: aliceIdentity,
        ourEphemeralKey: aliceEph,
        theirIdentityKey: bobIdentityPub,
        theirSignedPreKey: bobSpkPub,
        theirOneTimePreKey: bobOtpPub,
      );
      final aliceSession = ChatCrypto.initSession(aliceRoot,
          remoteIdentityPub: bobIdentityPub.bytes);

      // 响应方 X3DH（用 init_payload 里的公钥）
      final aliceIdentityPub = await aliceIdentity.extractPublicKey();
      final aliceEphPub = await aliceEph.extractPublicKey();
      final bobRoot = await _responderX3dh(
        ourIdentity: bobIdentity,
        ourSpk: bobSpk.keyPair,
        ourOtp: bobOtp,
        theirIdentityPub: aliceIdentityPub,
        theirEphPub: aliceEphPub,
      );
      final bobSession = ChatCrypto.initSession(bobRoot,
          remoteIdentityPub: aliceIdentityPub.bytes);

      // 两端 sessionKey 必须一致
      expect(
        aliceSession.sessionKey,
        bobSession.sessionKey,
        reason: '两端 X3DH 协商出的 session key 必须一致',
      );

      // 加解密验证
      final senderAad = ChatCrypto.associatedData(
        senderUserId: alice,
        recipientUserId: bob,
        conversationId: 'conv-bob',
      );
      final receiverAad = ChatCrypto.associatedData(
        senderUserId: bob,
        recipientUserId: alice,
        conversationId: 'conv-alice',
      );
      final enc = await ChatCrypto.encryptMessage(
          aliceSession, utf8.encode('x3dh hello'), messageId: 'x1', aad: senderAad);
      final dec = await ChatCrypto.decryptMessage(
          bobSession, enc.ciphertext,
          messageId: 'x1', counter: enc.counter, aad: receiverAad);
      expect(utf8.decode(dec.plaintext), 'x3dh hello');
    });

    test('x3dhKeyAgreement and manual 4xDH produce SAME root for same inputs',
        () async {
      // 决定性：用**完全相同**的密钥材料，分别走发起方路径(x3dhKeyAgreement)
      // 和响应方路径(手动 DH1||DH2||DH3||DH4)。若结果不同 → 两条路径算法 bug
      // → 真机两端 key 不一致 → 解密 MAC 失败。这是真机失配的最后可能根因。
      final x = cryptography.X25519();

      // 同一套材料：Alice IK/EK 私钥，Bob IK/SPK/OTP 公钥
      final aliceIdentity = await CryptoManager.generateIdentityKeyPair();
      final aliceEph = await CryptoManager.generateIdentityKeyPair();
      final bobIdentity = await CryptoManager.generateIdentityKeyPair();
      final bobSpk = await CryptoManager.generateSignedPreKey();
      final bobOtps = await CryptoManager.generatePreKeys(1);
      final bobOtp = bobOtps.first;

      final bobIdentityPub = await bobIdentity.extractPublicKey();
      final bobSpkPub = await bobSpk.keyPair.extractPublicKey();
      final bobOtpPub = await bobOtp.extractPublicKey();
      final aliceIdentityPub = await aliceIdentity.extractPublicKey();
      final aliceEphPub = await aliceEph.extractPublicKey();

      // 发起方路径
      final rootA = await CryptoManager.x3dhKeyAgreement(
        ourIdentityKey: aliceIdentity,
        ourEphemeralKey: aliceEph,
        theirIdentityKey: bobIdentityPub,
        theirSignedPreKey: bobSpkPub,
        theirOneTimePreKey: bobOtpPub,
      );

      // 响应方路径（手动 4 次 DH，同 _responderX3dh）
      Future<List<int>> dh(
          cryptography.SimpleKeyPair ours, cryptography.SimplePublicKey theirs) async {
        final sk = await x.sharedSecretKey(keyPair: ours, remotePublicKey: theirs);
        return await sk.extractBytes();
      }
      final secrets = <List<int>>[
        await dh(bobSpk.keyPair, aliceIdentityPub), // DH1 = DH(SPKb, IKa)
        await dh(bobIdentity, aliceEphPub), // DH2 = DH(IKb, EKa)
        await dh(bobSpk.keyPair, aliceEphPub), // DH3 = DH(SPKb, EKa)
        await dh(bobOtp, aliceEphPub), // DH4 = DH(OPKb, EKa)
      ];
      final concat = Uint8List(secrets.fold<int>(0, (s, p) => s + p.length));
      var off = 0;
      for (final part in secrets) {
        concat.setRange(off, off + part.length, part);
        off += part.length;
      }
      final rootB = await CryptoManager.hkdf(concat, 'MyPhone-X3DH-v1', 32);

      expect(
        rootA,
        rootB,
        reason: '相同材料下 x3dhKeyAgreement 与手动 4xDH 必须算出相同 root key',
      );
    });

    test('restored keypair produces SAME DH as original', () async {
      // 决定性：响应方用 restoreX25519KeyPair 恢复的 keyPair 做 DH。若恢复路径
      // 的私钥格式与原始 SimpleKeyPair 不一致 → DH 值不同 → 两端 key 不同 →
      // MAC 失败。验证恢复后 DH 与原始一致。
      final x = cryptography.X25519();
      final other = await CryptoManager.generateIdentityKeyPair();
      final otherPub = await other.extractPublicKey();

      final original = await CryptoManager.generateIdentityKeyPair();
      final dhOriginal =
          await x.sharedSecretKey(keyPair: original, remotePublicKey: otherPub);
      final dhOriginalBytes = await dhOriginal.extractBytes();

      // 走 export + restore 恢复路径
      final stored = await CryptoManager.exportKeyPair(original);
      final restored = CryptoManager.restoreX25519KeyPair(
        privateKey: stored.privateKey,
        publicKey: stored.publicKey,
      );
      final dhRestored =
          await x.sharedSecretKey(keyPair: restored, remotePublicKey: otherPub);
      final dhRestoredBytes = await dhRestored.extractBytes();

      expect(
        dhRestoredBytes,
        dhOriginalBytes,
        reason: 'restoreX25519KeyPair 恢复的 keyPair 必须与原始算出相同 DH',
      );
    });

    test('counter in AAD binding rejects renumbered counter', () async {
      final (a, b) = makePair();
      final enc = await ChatCrypto.encryptMessage(
          a, utf8.encode('hi'), messageId: 'm1', aad: ad(alice, bob));
      await expectLater(
        ChatCrypto.decryptMessage(b, enc.ciphertext,
            messageId: 'm1', counter: 3, aad: ad(alice, bob)),
        throwsA(isA<ChatCryptoException>()),
      );
    });

    test('messageId binding rejects changed messageId', () async {
      final (a, b) = makePair();
      final enc = await ChatCrypto.encryptMessage(
          a, utf8.encode('hi'), messageId: 'm1', aad: ad(alice, bob));
      await expectLater(
        ChatCrypto.decryptMessage(b, enc.ciphertext,
            messageId: 'm2', counter: enc.counter, aad: ad(alice, bob)),
        throwsA(isA<ChatCryptoException>()),
      );
    });

    test('persistence round trip continues', () async {
      final (a, b) = makePair();
      final enc = await ChatCrypto.encryptMessage(
          a, utf8.encode('m1'), messageId: 'm1', aad: ad(alice, bob));
      final dec = await ChatCrypto.decryptMessage(b, enc.ciphertext,
          messageId: 'm1', counter: enc.counter, aad: ad(alice, bob));

      final restoredA = ChatCryptoSession.fromJson(enc.session.toJson());
      final restoredB = ChatCryptoSession.fromJson(dec.session.toJson());
      expect(restoredA.sendCounter, 2);
      expect(restoredB.recvCounter, 1);

      final enc2 = await ChatCrypto.encryptMessage(restoredA,
          utf8.encode('m2'), messageId: 'm2', aad: ad(alice, bob));
      final dec2 = await ChatCrypto.decryptMessage(restoredB, enc2.ciphertext,
          messageId: 'm2', counter: enc2.counter, aad: ad(alice, bob));
      expect(utf8.decode(dec2.plaintext), 'm2');
      expect(dec2.session.recvCounter, 2);
    });

    test('legacy Double Ratchet JSON rejected', () {
      expect(
        () => ChatCryptoSession.fromJson({'root_key': 'aa', 'send_counter': 1}),
        throwsA(isA<ChatCryptoException>()),
      );
    });

    test('nonce is unique across 1000 messages', () async {
      final (a, _) = makePair();
      var session = a;
      final nonces = <String>{};
      for (var i = 1; i <= 1000; i++) {
        final enc = await ChatCrypto.encryptMessage(session, utf8.encode('x'),
            messageId: 'm$i', aad: ad(alice, bob));
        session = enc.session;
        nonces.add(enc.ciphertext.sublist(0, 12).toString());
      }
      expect(nonces.length, 1000);
    });
  });
}
