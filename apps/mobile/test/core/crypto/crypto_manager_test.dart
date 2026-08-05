import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myphone/core/crypto/crypto_manager.dart';

void main() {
  group('CryptoManager call E2EE primitives', () {
    test('deriveCallSecrets produces the same secrets on both peers', () async {
      final aliceIdentity = await CryptoManager.generateIdentityKeyPair();
      final aliceEphemeral = await CryptoManager.generateIdentityKeyPair();
      final bobIdentity = await CryptoManager.generateIdentityKeyPair();
      final bobEphemeral = await CryptoManager.generateIdentityKeyPair();

      final aliceSecrets = await CryptoManager.deriveCallSecrets(
        localIsOfferer: true,
        localIdentityKey: aliceIdentity,
        localEphemeralKey: aliceEphemeral,
        remoteIdentityKey: await bobIdentity.extractPublicKey(),
        remoteEphemeralKey: await bobEphemeral.extractPublicKey(),
        callId: 'call-123',
        callSalt: List<int>.generate(32, (index) => index),
      );

      final bobSecrets = await CryptoManager.deriveCallSecrets(
        localIsOfferer: false,
        localIdentityKey: bobIdentity,
        localEphemeralKey: bobEphemeral,
        remoteIdentityKey: await aliceIdentity.extractPublicKey(),
        remoteEphemeralKey: await aliceEphemeral.extractPublicKey(),
        callId: 'call-123',
        callSalt: List<int>.generate(32, (index) => index),
      );

      expect(aliceSecrets.mediaKey, orderedEquals(bobSecrets.mediaKey));
      expect(aliceSecrets.controlKey, orderedEquals(bobSecrets.controlKey));
      expect(aliceSecrets.ratchetSalt, orderedEquals(bobSecrets.ratchetSalt));
    });

    test('signature verification rejects tampered payloads', () async {
      final signingKeyPair = await CryptoManager.generateSigningKeyPair();
      final signingPublicKey = await signingKeyPair.extractPublicKey();
      final payload = Uint8List.fromList('secure-control-payload'.codeUnits);

      final signature = await CryptoManager.signBytes(payload, signingKeyPair);

      expect(
        await CryptoManager.verifySignature(
          payload: payload,
          signature: signature,
          signingPublicKey: signingPublicKey,
        ),
        isTrue,
      );

      expect(
        await CryptoManager.verifySignature(
          payload: Uint8List.fromList('tampered-control-payload'.codeUnits),
          signature: signature,
          signingPublicKey: signingPublicKey,
        ),
        isFalse,
      );
    });

    test('canonicalJson stays stable across map order changes', () {
      final left = {
        'z': 1,
        'a': {
          'c': 3,
          'b': 2,
        },
      };
      final right = {
        'a': {
          'b': 2,
          'c': 3,
        },
        'z': 1,
      };

      expect(CryptoManager.canonicalJson(left), CryptoManager.canonicalJson(right));
    });

    test('handshakeDigest stays stable across map order changes', () {
      final left = {
        'call_id': 'call-1',
        'role': 'offer',
        'sender_user_id': 'alice',
        'receiver_user_id': 'bob',
        'identity_public_key': '01',
      };
      final right = {
        'identity_public_key': '01',
        'receiver_user_id': 'bob',
        'sender_user_id': 'alice',
        'role': 'offer',
        'call_id': 'call-1',
      };

      expect(CryptoManager.handshakeDigest(left), CryptoManager.handshakeDigest(right));
    });

    test('handshakeDigest changes when participant binding changes', () {
      final baseline = {
        'call_id': 'call-1',
        'role': 'offer',
        'sender_user_id': 'alice',
        'receiver_user_id': 'bob',
        'identity_public_key': '01',
      };
      final rebound = {
        'call_id': 'call-1',
        'role': 'offer',
        'sender_user_id': 'mallory',
        'receiver_user_id': 'bob',
        'identity_public_key': '01',
      };

      expect(
        CryptoManager.handshakeDigest(baseline),
        isNot(CryptoManager.handshakeDigest(rebound)),
      );
    });

    test('rotation and integrity operations stay within latency budget', () async {
      final currentMediaKey = Uint8List.fromList(
        List<int>.generate(32, (index) => index + 1),
      );
      final rotationSeed = Uint8List.fromList(
        List<int>.generate(16, (index) => 255 - index),
      );
      final payload = Uint8List.fromList(
        List<int>.generate(128, (index) => index % 251),
      );

      const iterations = 50;
      final stopwatch = Stopwatch()..start();
      Uint8List? rotatedKey;
      for (var index = 0; index < iterations; index++) {
        rotatedKey = await CryptoManager.deriveRotatedMediaKey(
          currentMediaKey: currentMediaKey,
          rotationSeed: rotationSeed,
          callId: 'call-rotate',
          keyIndex: index,
        );
        await CryptoManager.hmacSha256(payload, rotatedKey);
      }
      stopwatch.stop();

      final averageLatencyMs = stopwatch.elapsedMicroseconds / iterations / 1000;
      debugPrint(
        'E2EE primitive average latency: ${averageLatencyMs.toStringAsFixed(3)} ms',
      );
      expect(rotatedKey, isNotNull);
      expect(averageLatencyMs, lessThan(100));
    });
  });
}
