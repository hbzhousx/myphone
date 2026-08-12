import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myphone/core/crypto/crypto_manager.dart';

void main() {
  test('initiator and responder derive identical X3DH root key', () async {
    // Bob 的 bundle：identity + signed prekey + one-time prekey。
    final bobIdentity = await CryptoManager.generateIdentityKeyPair();
    final bobSpk = await CryptoManager.generateSignedPreKey();
    final bobOtp = await CryptoManager.generatePreKeys(1);
    final bobOtpPub = await bobOtp.first.extractPublicKey();

    // Alice 发起方 X3DH。
    final aliceIdentity = await CryptoManager.generateIdentityKeyPair();
    final aliceEph = await CryptoManager.generateIdentityKeyPair();
    final aliceRoot = await CryptoManager.x3dhKeyAgreement(
      ourIdentityKey: aliceIdentity,
      ourEphemeralKey: aliceEph,
      theirIdentityKey: await bobIdentity.extractPublicKey(),
      theirSignedPreKey: await bobSpk.keyPair.extractPublicKey(),
      theirOneTimePreKey: bobOtpPub,
    );

    // Bob 响应方 X3DH（手动，与 manager 内逻辑一致）。
    final bobSpkData = await _toData(bobSpk.keyPair);
    final bobOtpData = await _toData(bobOtp.first);
    final bobIdentityData = await _toData(bobIdentity);
    final secrets = <List<int>>[
      await _dh(bobSpkData, await aliceIdentity.extractPublicKey()), // DH1
      await _dh(bobIdentityData, await aliceEph.extractPublicKey()), // DH2
      await _dh(bobSpkData, await aliceEph.extractPublicKey()), // DH3
      await _dh(bobOtpData, await aliceEph.extractPublicKey()), // DH4
    ];
    final bobRoot =
        await CryptoManager.hkdf(_concat(secrets), 'MyPhone-X3DH-v1', 32);

    expect(aliceRoot, orderedEquals(bobRoot));
  });
}

Future<List<int>> _dh(SimpleKeyPairData ours, SimplePublicKey theirs) async {
  final x = X25519();
  final sk = await x.sharedSecretKey(keyPair: ours, remotePublicKey: theirs);
  return sk.extractBytes();
}

Future<SimpleKeyPairData> _toData(SimpleKeyPair pair) async {
  final extracted = await pair.extract();
  return CryptoManager.restoreX25519KeyPair(
    privateKey: await extracted.extractPrivateKeyBytes(),
    publicKey: extracted.publicKey.bytes,
  );
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
