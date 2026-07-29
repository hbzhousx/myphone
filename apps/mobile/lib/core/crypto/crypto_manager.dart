/// Signal Protocol cryptography using the `cryptography` package.
///
/// X3DH key agreement + Double Ratchet + AES-256-GCM + HKDF-SHA256.
library;

import 'dart:typed_data';
import 'dart:convert' as dart_convert;
import 'package:convert/convert.dart';
import 'package:cryptography/cryptography.dart';
import 'package:crypto/crypto.dart' as crypto;

class CryptoManager {
  static Future<SimpleKeyPair> generateIdentityKeyPair() =>
      X25519().newKeyPair();

  static Future<List<SimpleKeyPair>> generatePreKeys(int count) async {
    final pairs = <SimpleKeyPair>[];
    for (var i = 0; i < count; i++) {
      pairs.add(await X25519().newKeyPair());
    }
    return pairs;
  }

  static Future<SignedPreKey> generateSignedPreKey() async {
    final keyPair = await X25519().newKeyPair();
    final signingKey = await Ed25519().newKeyPair();
    final pubKey = await keyPair.extractPublicKey();
    final signature = await Ed25519().sign(pubKey.bytes, keyPair: signingKey);
    return SignedPreKey(
      keyPair: keyPair,
      signature: signature.bytes,
      signingPublicKey: await signingKey.extractPublicKey(),
    );
  }

  /// X3DH: DH1||DH2||DH3||DH4 → HKDF → root key.
  static Future<Uint8List> x3dhKeyAgreement({
    required SimpleKeyPair ourIdentityKey,
    required SimpleKeyPair ourEphemeralKey,
    required SimplePublicKey theirIdentityKey,
    required SimplePublicKey theirSignedPreKey,
    SimplePublicKey? theirOneTimePreKey,
  }) async {
    final x = X25519();

    Future<List<int>> dh(SimpleKeyPair ours, SimplePublicKey theirs) async {
      final sk = await x.sharedSecretKey(
        keyPair: ours, remotePublicKey: theirs);
      return await sk.extractBytes();
    }

    final secrets = <List<int>>[
      await dh(ourIdentityKey, theirSignedPreKey),
      await dh(ourEphemeralKey, theirIdentityKey),
      await dh(ourEphemeralKey, theirSignedPreKey),
      if (theirOneTimePreKey != null)
        await dh(ourEphemeralKey, theirOneTimePreKey),
    ];

    return _concatAndKdf(secrets, 'MyPhone-X3DH-v1', 32);
  }

  static RatchetSession initializeRatchet(Uint8List rootKey) =>
      RatchetSession(rootKey: rootKey);

  /// Ratchet-encrypt: DH forward → derive message key → AES-256-GCM.
  static Future<EncryptResult> ratchetEncrypt(
    RatchetSession s, Uint8List pt) async {
    final x = X25519();
    final ourEph = await x.newKeyPair();

    // DH ratchet forward
    List<int> dhOut;
    if (s.remoteEphemeralKey != null) {
      final sk = await x.sharedSecretKey(
        keyPair: ourEph, remotePublicKey: s.remoteEphemeralKey!);
      dhOut = await sk.extractBytes();
    } else {
      dhOut = List<int>.filled(32, 0);
    }

    // HKDF: rootKey || dhOut → newRoot + chainKey
    final ikm = Uint8List(s.rootKey.length + dhOut.length);
    ikm.setRange(0, s.rootKey.length, s.rootKey);
    ikm.setRange(s.rootKey.length, ikm.length, dhOut);
    final kdf = await _hkdf(ikm, 'MyPhone-Ratchet-v1', 64);
    final newRoot = Uint8List.sublistView(kdf, 0, 32);
    final ck = Uint8List.sublistView(kdf, 32, 64);

    // Derive message key from chain key
    final mk = await _hkdf(ck, 'MyPhone-Message-v1', 32);

    // AES-256-GCM encrypt
    final aes = AesGcm.with256bits(nonceLength: 12);
    final nonce = _random12();
    final box = await aes.encrypt(pt, secretKey: SecretKey(mk), nonce: nonce);

    final ct = Uint8List(12 + box.cipherText.length + box.mac.bytes.length);
    ct.setRange(0, 12, nonce);
    ct.setRange(12, 12 + box.cipherText.length, box.cipherText);
    ct.setRange(12 + box.cipherText.length, ct.length, box.mac.bytes);

    return EncryptResult(
      ciphertext: ct,
      session: RatchetSession(
        rootKey: newRoot,
        ourEphemeralKey: ourEph,
        remoteEphemeralKey: s.remoteEphemeralKey,
        messageNumber: s.messageNumber + 1,
      ),
    );
  }

  /// Ratchet-decrypt: derive message key → AES-256-GCM decrypt.
  static Future<DecryptResult> ratchetDecrypt(
    RatchetSession s, Uint8List ct) async {
    final nonceBytes = Uint8List.fromList(ct.sublist(0, 12));
    final macBytes = Uint8List.fromList(ct.sublist(ct.length - 16));
    final enc = Uint8List.fromList(ct.sublist(12, ct.length - 16));

    final mk = await _hkdf(s.rootKey, 'MyPhone-Message-v1', 32);

    final aes = AesGcm.with256bits(nonceLength: 12);
    final pt = Uint8List.fromList(await aes.decrypt(
      SecretBox(enc, nonce: nonceBytes, mac: Mac(macBytes)),
      secretKey: SecretKey(mk),
    ));

    return DecryptResult(
      plaintext: pt,
      session: RatchetSession(
        rootKey: s.rootKey,
        ourEphemeralKey: s.ourEphemeralKey,
        remoteEphemeralKey: s.remoteEphemeralKey,
        messageNumber: s.messageNumber + 1,
      ),
    );
  }

  /// SHA-256 phone hash (salted).
  static String sha256Hash(String input, {String salt = 'myphone-contact-v1'}) {
    final bytes = dart_convert.utf8.encode(salt + input);
    return crypto.sha256.convert(bytes).toString();
  }

  /// HKDF-SHA256 derive.
  static Future<Uint8List> _hkdf(List<int> ikm, String info, int len) async {
    final hkdf = Hkdf(hmac: Hmac(Sha256()), outputLength: len);
    final sk = await hkdf.deriveKey(
      secretKey: SecretKey(ikm),
      nonce: List<int>.filled(32, 0),
      info: dart_convert.utf8.encode(info),
    );
    return Uint8List.fromList(sk.bytes);
  }

  static Future<Uint8List> _concatAndKdf(
    List<List<int>> parts, String info, int len) async {
    return _hkdf(_concat(parts), info, len);
  }

  static Uint8List _concat(List<List<int>> parts) {
    final total = parts.fold<int>(0, (s, p) => s + p.length);
    final r = Uint8List(total);
    var off = 0;
    for (final p in parts) { r.setRange(off, off + p.length, p); off += p.length; }
    return r;
  }

  static List<int> _random12() =>
      List<int>.generate(12, (i) => (DateTime.now().microsecondsSinceEpoch >> (i * 3)) & 0xFF);

  static String keyToHex(SimplePublicKey key) => hex.encode(key.bytes);

  static SimplePublicKey keyFromHex(String h) =>
      SimplePublicKey(Uint8List.fromList(hex.decode(h)), type: KeyPairType.x25519);
}

/// Double Ratchet session.
class RatchetSession {
  final Uint8List rootKey;
  final SimpleKeyPair? ourEphemeralKey;
  final SimplePublicKey? remoteEphemeralKey;
  final int messageNumber;

  const RatchetSession({
    required this.rootKey,
    this.ourEphemeralKey,
    this.remoteEphemeralKey,
    this.messageNumber = 0,
  });
}

class SignedPreKey {
  final SimpleKeyPair keyPair;
  final List<int> signature;
  final PublicKey signingPublicKey;
  const SignedPreKey({
    required this.keyPair,
    required this.signature,
    required this.signingPublicKey,
  });
}

class EncryptResult {
  final Uint8List ciphertext;
  final RatchetSession session;
  const EncryptResult({required this.ciphertext, required this.session});
}

class DecryptResult {
  final Uint8List plaintext;
  final RatchetSession session;
  const DecryptResult({required this.plaintext, required this.session});
}
