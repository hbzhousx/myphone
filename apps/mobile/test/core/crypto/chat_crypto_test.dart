import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:myphone/core/crypto/chat_crypto.dart';
import 'package:myphone/core/crypto/crypto_manager.dart';

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
