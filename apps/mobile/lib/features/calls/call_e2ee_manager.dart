library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

import '../../core/crypto/crypto_manager.dart';
import '../../core/storage/database.dart';
import '../../core/webrtc/webrtc_manager.dart';

enum CallE2eeStage { idle, negotiating, encrypted, warning, failed }

class CallE2eeSnapshot {
  final CallE2eeStage stage;
  final String status;
  final String? peerFingerprint;
  final bool trustedPeer;
  final int keyIndex;
  final int rotationCount;
  final int replayDrops;

  const CallE2eeSnapshot({
    required this.stage,
    required this.status,
    this.peerFingerprint,
    this.trustedPeer = false,
    this.keyIndex = 0,
    this.rotationCount = 0,
    this.replayDrops = 0,
  });

  bool get isEncrypted => stage == CallE2eeStage.encrypted;

  CallE2eeSnapshot copyWith({
    CallE2eeStage? stage,
    String? status,
    String? peerFingerprint,
    bool? trustedPeer,
    int? keyIndex,
    int? rotationCount,
    int? replayDrops,
  }) {
    return CallE2eeSnapshot(
      stage: stage ?? this.stage,
      status: status ?? this.status,
      peerFingerprint: peerFingerprint ?? this.peerFingerprint,
      trustedPeer: trustedPeer ?? this.trustedPeer,
      keyIndex: keyIndex ?? this.keyIndex,
      rotationCount: rotationCount ?? this.rotationCount,
      replayDrops: replayDrops ?? this.replayDrops,
    );
  }
}

class CallE2eeManager {
  static const _identityKeyType = 'e2ee_identity_x25519';
  static const _signingKeyType = 'e2ee_signing_ed25519';
  static const _rotationInterval = Duration(minutes: 2);
  static const _maxClockSkewMs = 5 * 60 * 1000;
  static const _maxNonceHistory = 128;

  final String callId;
  final String localUserId;
  final String remoteUserId;
  final bool localIsOfferer;
  final WebrtcManager webrtc;
  final Future<void> Function(Map<String, dynamic> payload) sendRotationPayload;
  final void Function(CallE2eeSnapshot snapshot)? onStateChanged;
  final DatabaseManager _database;
  final rtc.FrameCryptorFactory _frameCryptorFactory;

  _LocalIdentityBundle? _localIdentity;
  rtc.KeyProvider? _keyProvider;
  final Map<String, rtc.FrameCryptor> _frameCryptors = {};
  final Set<String> _recentRemoteNonces = <String>{};

  SimpleKeyPairData? _localEphemeralKey;
  SimplePublicKey? _remoteIdentityPublicKey;
  SimplePublicKey? _remoteEphemeralPublicKey;
  Uint8List? _callSalt;
  Uint8List? _mediaKey;
  Uint8List? _controlKey;
  Uint8List? _ratchetSalt;
  String? _localOfferDigest;
  String? _remoteOfferDigest;

  CallE2eeSnapshot _snapshot = const CallE2eeSnapshot(
    stage: CallE2eeStage.idle,
    status: 'Negotiating end-to-end encryption',
  );
  Timer? _rotationTimer;
  int _keyIndex = 0;
  int _localSequence = 0;
  int _highestRemoteSequence = 0;
  int _rotationCount = 0;
  int _replayDrops = 0;
  bool _disposed = false;

  CallE2eeManager({
    required this.callId,
    required this.localUserId,
    required this.remoteUserId,
    required this.localIsOfferer,
    required this.webrtc,
    required this.sendRotationPayload,
    this.onStateChanged,
    DatabaseManager? database,
    rtc.FrameCryptorFactory? frameCryptorFactory,
  })  : _database = database ?? DatabaseManager.instance,
        _frameCryptorFactory = frameCryptorFactory ?? rtc.frameCryptorFactory;

  CallE2eeSnapshot get snapshot => _snapshot;

  Future<Map<String, dynamic>> createOfferHandshake() async {
    _emit(_snapshot.copyWith(
      stage: CallE2eeStage.negotiating,
      status: 'Negotiating end-to-end encryption',
    ));
    await _ensureLocalIdentity();
    _localEphemeralKey ??= await _newX25519KeyPair();
    _callSalt ??= CryptoManager.randomBytes(32);
    return _buildHandshakePayload(role: 'offer');
  }

  Future<Map<String, dynamic>> createAnswerHandshake(
    Map<String, dynamic> remoteHandshake,
  ) async {
    _emit(_snapshot.copyWith(
      stage: CallE2eeStage.negotiating,
      status: 'Negotiating end-to-end encryption',
    ));
    await _ensureLocalIdentity();
    _localEphemeralKey ??= await _newX25519KeyPair();
    await _consumeRemoteHandshake(remoteHandshake, expectedRole: 'offer');
    await _deriveAndApplySharedSecrets();
    return _buildHandshakePayload(role: 'answer');
  }

  Future<void> completeWithAnswer(Map<String, dynamic> remoteHandshake) async {
    await _consumeRemoteHandshake(remoteHandshake, expectedRole: 'answer');
    await _deriveAndApplySharedSecrets();
  }

  Future<void> synchronizeFrameCryptors() async {
    if (_mediaKey == null || _keyProvider == null) {
      return;
    }
    await _installSenderCryptors();
    await _installReceiverCryptors();
  }

  Future<void> handleRotation(Map<String, dynamic> payload) async {
    final envelope =
        Map<String, dynamic>.from(payload['envelope'] as Map<String, dynamic>);
    final mac = payload['mac'] as String?;
    if (mac == null || _controlKey == null || _mediaKey == null) {
      throw StateError('Missing key rotation material');
    }

    _assertFreshInboundEnvelope(envelope);

    final expectedMac = await CryptoManager.hmacSha256(
      utf8.encode(CryptoManager.canonicalJson(envelope)),
      _controlKey!,
    );
    if (hex.encode(expectedMac) != mac) {
      throw StateError('Rotation control message integrity check failed');
    }

    final nextKeyIndex = envelope['key_index'] as int;
    final seed = hex.decode(envelope['rotation_seed'] as String);
    final rotatedKey = await CryptoManager.deriveRotatedMediaKey(
      currentMediaKey: _mediaKey!,
      rotationSeed: seed,
      callId: callId,
      keyIndex: nextKeyIndex,
    );
    await _applyMediaKey(rotatedKey, nextKeyIndex);
    _rotationCount++;
    _emit(_snapshot.copyWith(
      stage: CallE2eeStage.encrypted,
      status: 'End-to-end encrypted',
      keyIndex: _keyIndex,
      rotationCount: _rotationCount,
      replayDrops: _replayDrops,
    ));
  }

  Future<void> dispose() async {
    _disposed = true;
    _rotationTimer?.cancel();
    _rotationTimer = null;
    for (final cryptor in _frameCryptors.values) {
      await cryptor.dispose();
    }
    _frameCryptors.clear();
    await _keyProvider?.dispose();
    _keyProvider = null;
  }

  Future<void> _ensureLocalIdentity() async {
    if (_localIdentity != null) {
      return;
    }

    final identityKey = await _loadOrCreateKeyPair(
      baseKeyType: _identityKeyType,
      generator: CryptoManager.generateIdentityKeyPair,
      restore: CryptoManager.restoreX25519KeyPair,
    );
    final signingKey = await _loadOrCreateKeyPair(
      baseKeyType: _signingKeyType,
      generator: CryptoManager.generateSigningKeyPair,
      restore: CryptoManager.restoreEd25519KeyPair,
    );

    final identityPublicKey = await identityKey.extractPublicKey();
    _localIdentity = _LocalIdentityBundle(
      identityKey: identityKey,
      signingKey: signingKey,
      fingerprint: CryptoManager.fingerprintFromPublicKey(
        identityPublicKey.bytes,
      ),
    );
  }

  Future<SimpleKeyPairData> _loadOrCreateKeyPair({
    required String baseKeyType,
    required Future<SimpleKeyPair> Function() generator,
    required SimpleKeyPairData Function({
      required List<int> privateKey,
      required List<int> publicKey,
    }) restore,
  }) async {
    final privateKey = await _database.getKey('${baseKeyType}_private');
    final publicKey = await _database.getKey('${baseKeyType}_public');

    if (privateKey != null && publicKey != null) {
      return restore(privateKey: privateKey, publicKey: publicKey);
    }

    final keyPair = await generator();
    final exported = await CryptoManager.exportKeyPair(keyPair);
    await _database.storeKey('${baseKeyType}_private', exported.privateKey);
    await _database.storeKey('${baseKeyType}_public', exported.publicKey);
    return restore(
      privateKey: exported.privateKey,
      publicKey: exported.publicKey,
    );
  }

  Future<Map<String, dynamic>> _buildHandshakePayload({
    required String role,
  }) async {
    final localIdentity = _localIdentity!;
    final identityPublicKey = await localIdentity.identityKey.extractPublicKey();
    final signingPublicKey = await localIdentity.signingKey.extractPublicKey();
    final ephemeralPublicKey = await _localEphemeralKey!.extractPublicKey();

    final envelope = <String, dynamic>{
      'version': 1,
      'call_id': callId,
      'role': role,
      'sender_user_id': localUserId,
      'receiver_user_id': remoteUserId,
      'identity_public_key': hex.encode(identityPublicKey.bytes),
      'signing_public_key': hex.encode(signingPublicKey.bytes),
      'ephemeral_public_key': hex.encode(ephemeralPublicKey.bytes),
      'fingerprint': localIdentity.fingerprint,
      'sequence': ++_localSequence,
      'timestamp_ms': DateTime.now().millisecondsSinceEpoch,
      'nonce': CryptoManager.randomNonce(),
      if (role == 'offer' && _callSalt != null) 'call_salt': hex.encode(_callSalt!),
      if (role == 'answer' && _remoteOfferDigest != null) 'offer_hash': _remoteOfferDigest,
    };

    if (role == 'offer') {
      _localOfferDigest = CryptoManager.handshakeDigest(envelope);
    }

    final signature = await CryptoManager.signBytes(
      utf8.encode(CryptoManager.canonicalJson(envelope)),
      localIdentity.signingKey,
    );

    return {
      'envelope': envelope,
      'signature': hex.encode(signature),
    };
  }

  Future<void> _consumeRemoteHandshake(
    Map<String, dynamic> handshake,
    {required String expectedRole}
  ) async {
    final envelope =
        Map<String, dynamic>.from(handshake['envelope'] as Map<String, dynamic>);
    final signatureHex = handshake['signature'] as String?;
    if (signatureHex == null) {
      throw StateError('Missing remote handshake signature');
    }

    _assertValidHandshakeEnvelope(envelope, expectedRole: expectedRole);
    _assertFreshInboundEnvelope(envelope);

    final signingPublicKey = await CryptoManager.signingKeyFromHex(
      envelope['signing_public_key'] as String,
    );
    final signature = hex.decode(signatureHex);
    final isValid = await CryptoManager.verifySignature(
      payload: utf8.encode(CryptoManager.canonicalJson(envelope)),
      signature: signature,
      signingPublicKey: signingPublicKey,
    );
    if (!isValid) {
      throw StateError('Remote handshake signature verification failed');
    }

    final remoteIdentityPublicKey = CryptoManager.keyFromHex(
      envelope['identity_public_key'] as String,
    );
    final trustedPeer = await _trustOrVerifyRemoteIdentity(
      remoteIdentityPublicKey.bytes,
      signingPublicKey.bytes,
      envelope['fingerprint'] as String?,
    );

    _remoteIdentityPublicKey = remoteIdentityPublicKey;
    _remoteEphemeralPublicKey = CryptoManager.keyFromHex(
      envelope['ephemeral_public_key'] as String,
    );

    final callSaltHex = envelope['call_salt'] as String?;
    if (callSaltHex != null) {
      _callSalt = Uint8List.fromList(hex.decode(callSaltHex));
    }
    if (expectedRole == 'offer') {
      _remoteOfferDigest = CryptoManager.handshakeDigest(envelope);
    } else if (expectedRole == 'answer') {
      final offerHash = envelope['offer_hash'] as String?;
      if (_localOfferDigest == null || offerHash != _localOfferDigest) {
        throw StateError('Remote answer is not bound to the current offer');
      }
    }

    _emit(_snapshot.copyWith(
      stage: CallE2eeStage.negotiating,
      status: trustedPeer
          ? 'Negotiating end-to-end encryption'
          : 'Verifying peer identity',
      trustedPeer: trustedPeer,
      peerFingerprint: envelope['fingerprint'] as String?,
      replayDrops: _replayDrops,
    ));
  }

  Future<bool> _trustOrVerifyRemoteIdentity(
    List<int> remoteIdentityKey,
    List<int> remoteSigningKey,
    String? advertisedFingerprint,
  ) async {
    final identityKeyName = 'remote_identity_public_$remoteUserId';
    final signingKeyName = 'remote_signing_public_$remoteUserId';
    final storedIdentityKey = await _database.getKey(identityKeyName);
    final storedSigningKey = await _database.getKey(signingKeyName);
    final fingerprint = advertisedFingerprint ??
        CryptoManager.fingerprintFromPublicKey(remoteIdentityKey);

    if (storedIdentityKey == null && storedSigningKey == null) {
      await _database.storeKey(identityKeyName, remoteIdentityKey);
      await _database.storeKey(signingKeyName, remoteSigningKey);
      await _database.updateContactFingerprint(remoteUserId, fingerprint);
      return true;
    }

    if (storedIdentityKey == null ||
        hex.encode(storedIdentityKey) != hex.encode(remoteIdentityKey)) {
      _emit(_snapshot.copyWith(
        stage: CallE2eeStage.warning,
        status: 'Peer fingerprint changed',
        peerFingerprint: fingerprint,
        trustedPeer: false,
        replayDrops: _replayDrops,
      ));
      throw StateError('Remote identity fingerprint mismatch');
    }

    if (storedSigningKey == null ||
        hex.encode(storedSigningKey) != hex.encode(remoteSigningKey)) {
      _emit(_snapshot.copyWith(
        stage: CallE2eeStage.warning,
        status: 'Peer signing key changed',
        peerFingerprint: fingerprint,
        trustedPeer: false,
        replayDrops: _replayDrops,
      ));
      throw StateError('Remote signing key mismatch');
    }

    await _database.updateContactFingerprint(remoteUserId, fingerprint);
    return true;
  }

  void _assertValidHandshakeEnvelope(
    Map<String, dynamic> envelope, {
    required String expectedRole,
  }) {
    if (envelope['call_id'] != callId) {
      throw StateError('Handshake call ID mismatch');
    }
    if (envelope['role'] != expectedRole) {
      throw StateError('Unexpected handshake role');
    }
    if (envelope['sender_user_id'] != remoteUserId) {
      throw StateError('Handshake sender mismatch');
    }
    if (envelope['receiver_user_id'] != localUserId) {
      throw StateError('Handshake receiver mismatch');
    }
    if (expectedRole == 'offer' && envelope['call_salt'] == null) {
      throw StateError('Offer handshake is missing call salt');
    }
    if (expectedRole == 'answer' && envelope['offer_hash'] == null) {
      throw StateError('Answer handshake is missing offer binding');
    }
  }

  Future<void> _deriveAndApplySharedSecrets() async {
    if (_callSalt == null ||
        _remoteIdentityPublicKey == null ||
        _remoteEphemeralPublicKey == null ||
        _localEphemeralKey == null ||
        _localIdentity == null) {
      // Never silently continue without a media key — that produces one-way
      // audio (noise on one side, silence on the other).  Surface the failure
      // so the UI can abort the call cleanly instead.
      _emit(_snapshot.copyWith(
        stage: CallE2eeStage.failed,
        status: 'Key negotiation failed — missing handshake material',
        replayDrops: _replayDrops,
      ));
      throw StateError(
          'Cannot derive call secrets: missing handshake material '
          '(salt=${_callSalt != null}, remoteIdentity=${_remoteIdentityPublicKey != null}, '
          'remoteEphemeral=${_remoteEphemeralPublicKey != null}, '
          'localEphemeral=${_localEphemeralKey != null}, localIdentity=${_localIdentity != null})');
    }

    final secrets = await CryptoManager.deriveCallSecrets(
      localIsOfferer: localIsOfferer,
      localIdentityKey: _localIdentity!.identityKey,
      localEphemeralKey: _localEphemeralKey!,
      remoteIdentityKey: _remoteIdentityPublicKey!,
      remoteEphemeralKey: _remoteEphemeralPublicKey!,
      callId: callId,
      callSalt: _callSalt!,
    );

    _controlKey = secrets.controlKey;
    _ratchetSalt = secrets.ratchetSalt;
    await _applyMediaKey(secrets.mediaKey, 0);
    _startRotationTimer();

    _emit(_snapshot.copyWith(
      stage: CallE2eeStage.encrypted,
      status: 'End-to-end encrypted',
      keyIndex: _keyIndex,
      trustedPeer: true,
      replayDrops: _replayDrops,
    ));
  }

  Future<void> _applyMediaKey(Uint8List mediaKey, int keyIndex) async {
    _mediaKey = mediaKey;
    _keyIndex = keyIndex;
    _keyProvider ??= await _frameCryptorFactory.createDefaultKeyProvider(
      rtc.KeyProviderOptions(
        sharedKey: true,
        ratchetSalt: _ratchetSalt ?? CryptoManager.randomBytes(32),
        ratchetWindowSize: 32,
        keyRingSize: 16,
        discardFrameWhenCryptorNotReady: true,
        keyDerivationAlgorithm: rtc.KeyDerivationAlgorithm.kHKDF,
      ),
    );

    await _keyProvider!.setSharedKey(key: _mediaKey!, index: _keyIndex);
    await synchronizeFrameCryptors();
    for (final cryptor in _frameCryptors.values) {
      await cryptor.setKeyIndex(_keyIndex);
      await cryptor.setEnabled(true);
    }
  }

  Future<void> _installSenderCryptors() async {
    final pc = webrtc.peerConnection;
    if (pc == null || _keyProvider == null) {
      return;
    }

    final senders = await pc.getSenders();
    for (final sender in senders) {
      final track = sender.track;
      if (track == null) {
        continue;
      }
      final trackKind = track.kind ?? 'audio';
      final cryptorId = 'sender:${sender.senderId}';
      if (_frameCryptors.containsKey(cryptorId)) {
        continue;
      }
      final cryptor = await _frameCryptorFactory.createFrameCryptorForRtpSender(
        participantId: cryptorId,
        sender: sender,
        algorithm: rtc.Algorithm.kAesGcm,
        keyProvider: _keyProvider!,
      );
      cryptor.onFrameCryptorStateChanged = (_, state) {
        _handleFrameCryptorState(
          trackKind,
          state,
        );
      };
      await cryptor.setKeyIndex(_keyIndex);
      await cryptor.setEnabled(true);
      await cryptor.updateCodec(trackKind == 'audio' ? 'OPUS' : 'VP8');
      _frameCryptors[cryptorId] = cryptor;
    }
  }

  Future<void> _installReceiverCryptors() async {
    final pc = webrtc.peerConnection;
    if (pc == null || _keyProvider == null) {
      return;
    }

    final receivers = await pc.getReceivers();
    for (final receiver in receivers) {
      final track = receiver.track;
      if (track == null) {
        continue;
      }
      final trackKind = track.kind ?? 'audio';
      final cryptorId = 'receiver:${receiver.receiverId}';
      if (_frameCryptors.containsKey(cryptorId)) {
        continue;
      }
      final cryptor =
          await _frameCryptorFactory.createFrameCryptorForRtpReceiver(
        participantId: cryptorId,
        receiver: receiver,
        algorithm: rtc.Algorithm.kAesGcm,
        keyProvider: _keyProvider!,
      );
      cryptor.onFrameCryptorStateChanged = (_, state) {
        _handleFrameCryptorState(
          trackKind,
          state,
        );
      };
      await cryptor.setKeyIndex(_keyIndex);
      await cryptor.setEnabled(true);
      await cryptor.updateCodec(trackKind == 'audio' ? 'OPUS' : 'VP8');
      _frameCryptors[cryptorId] = cryptor;
    }
  }

  void _handleFrameCryptorState(
    String kind,
    rtc.FrameCryptorState state,
  ) {
    if (_disposed) {
      return;
    }

    if (state == rtc.FrameCryptorState.FrameCryptorStateOk ||
        state == rtc.FrameCryptorState.FrameCryptorStateKeyRatcheted) {
      _emit(_snapshot.copyWith(
        stage: CallE2eeStage.encrypted,
        status: 'End-to-end encrypted',
        keyIndex: _keyIndex,
        rotationCount: _rotationCount,
        replayDrops: _replayDrops,
      ));
      return;
    }

    if (state == rtc.FrameCryptorState.FrameCryptorStateDecryptionFailed ||
        state == rtc.FrameCryptorState.FrameCryptorStateEncryptionFailed ||
        state == rtc.FrameCryptorState.FrameCryptorStateMissingKey) {
      _emit(_snapshot.copyWith(
        stage: CallE2eeStage.warning,
        status: '${kind.toUpperCase()} media encryption needs attention',
        keyIndex: _keyIndex,
        rotationCount: _rotationCount,
        replayDrops: _replayDrops,
      ));
    }
  }

  void _startRotationTimer() {
    _rotationTimer?.cancel();
    _rotationTimer = Timer.periodic(_rotationInterval, (_) {
      unawaited(_rotateKey());
    });
  }

  Future<void> _rotateKey() async {
    if (_mediaKey == null || _controlKey == null || _disposed) {
      return;
    }

    final nextKeyIndex = (_keyIndex + 1) % 16;
    final rotationSeed = CryptoManager.randomBytes(16);
    final rotatedKey = await CryptoManager.deriveRotatedMediaKey(
      currentMediaKey: _mediaKey!,
      rotationSeed: rotationSeed,
      callId: callId,
      keyIndex: nextKeyIndex,
    );
    await _applyMediaKey(rotatedKey, nextKeyIndex);
    _rotationCount++;

    final envelope = <String, dynamic>{
      'version': 1,
      'call_id': callId,
      'sequence': ++_localSequence,
      'timestamp_ms': DateTime.now().millisecondsSinceEpoch,
      'nonce': CryptoManager.randomNonce(),
      'key_index': nextKeyIndex,
      'rotation_seed': hex.encode(rotationSeed),
    };
    final mac = await CryptoManager.hmacSha256(
      utf8.encode(CryptoManager.canonicalJson(envelope)),
      _controlKey!,
    );

    await sendRotationPayload({
      'envelope': envelope,
      'mac': hex.encode(mac),
    });

    _emit(_snapshot.copyWith(
      stage: CallE2eeStage.encrypted,
      status: 'End-to-end encrypted',
      keyIndex: _keyIndex,
      rotationCount: _rotationCount,
      replayDrops: _replayDrops,
    ));
  }

  void _assertFreshInboundEnvelope(Map<String, dynamic> envelope) {
    final sequence = envelope['sequence'] as int?;
    final timestampMs = envelope['timestamp_ms'] as int?;
    final nonce = envelope['nonce'] as String?;

    if (sequence == null || timestampMs == null || nonce == null) {
      throw StateError('Missing control envelope fields');
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    if ((now - timestampMs).abs() > _maxClockSkewMs) {
      throw StateError('Control message timestamp is outside allowed window');
    }

    if (_recentRemoteNonces.contains(nonce) || sequence <= _highestRemoteSequence) {
      _replayDrops++;
      _emit(_snapshot.copyWith(replayDrops: _replayDrops));
      throw StateError('Replay attack detected');
    }

    _highestRemoteSequence = sequence;
    _recentRemoteNonces.add(nonce);
    if (_recentRemoteNonces.length > _maxNonceHistory) {
      _recentRemoteNonces.remove(_recentRemoteNonces.first);
    }
  }

  Future<SimpleKeyPairData> _newX25519KeyPair() async {
    final keyPair = await CryptoManager.generateIdentityKeyPair();
    final exported = await CryptoManager.exportKeyPair(keyPair);
    return CryptoManager.restoreX25519KeyPair(
      privateKey: exported.privateKey,
      publicKey: exported.publicKey,
    );
  }

  void _emit(CallE2eeSnapshot snapshot) {
    _snapshot = snapshot;
    onStateChanged?.call(snapshot);
  }
}

class _LocalIdentityBundle {
  final SimpleKeyPairData identityKey;
  final SimpleKeyPairData signingKey;
  final String fingerprint;

  const _LocalIdentityBundle({
    required this.identityKey,
    required this.signingKey,
    required this.fingerprint,
  });
}
