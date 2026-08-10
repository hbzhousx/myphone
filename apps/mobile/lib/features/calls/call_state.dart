/// Call state management using Riverpod.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:uuid/uuid.dart';

import '../../app/auth_guard.dart';
import '../../core/network/api_client.dart';
import '../../core/network/service_bridge.dart';
import '../../core/network/signaling_client.dart';
import '../../core/crypto/crypto_manager.dart';
import '../../core/storage/database.dart';
import '../../core/webrtc/ice_policy.dart';
import '../../core/webrtc/network_monitor.dart';
import '../../core/webrtc/webrtc_manager.dart';
import 'call_e2ee_manager.dart';
import 'incoming_call_state.dart';

enum CallStatus { idle, ringing, connecting, connected, ended }

/// Thrown when the dialed number isn't registered on the server.
class CallNotFoundException implements Exception {
  const CallNotFoundException();
  @override
  String toString() => 'The number you dialed does not exist. Please dial again.';
}

class ActiveCall {
  final String callId;
  final String contactId;
  final String contactName;
  final bool isIncoming;
  final CallStatus status;
  final DateTime startTime;
  final DateTime? endTime;
  final int durationSeconds;
  final WebrtcManager webrtc;
  final NetworkMonitor networkMonitor;
  final SignalingClient signaling;
  final CallE2eeManager e2ee;
  final CallE2eeSnapshot e2eeSnapshot;
  final List<Map<String, Object?>> pendingRemoteIce;

  ActiveCall({
    required this.callId,
    required this.contactId,
    required this.contactName,
    required this.isIncoming,
    required this.status,
    required this.startTime,
    this.endTime,
    required this.webrtc,
    required this.networkMonitor,
    required this.signaling,
    required this.e2ee,
    required this.e2eeSnapshot,
    this.durationSeconds = 0,
    List<Map<String, Object?>>? pendingRemoteIce,
  }) : pendingRemoteIce = pendingRemoteIce ?? <Map<String, Object?>>[];

  ActiveCall copyWith({
    CallStatus? status,
    DateTime? endTime,
    int? durationSeconds,
    CallE2eeSnapshot? e2eeSnapshot,
    List<Map<String, Object?>>? nextPendingRemoteIce,
  }) {
    return ActiveCall(
      callId: callId,
      contactId: contactId,
      contactName: contactName,
      isIncoming: isIncoming,
      status: status ?? this.status,
      startTime: startTime,
      endTime: endTime ?? this.endTime,
      durationSeconds: durationSeconds ?? this.durationSeconds,
      webrtc: webrtc,
      networkMonitor: networkMonitor,
      signaling: signaling,
      e2ee: e2ee,
      e2eeSnapshot: e2eeSnapshot ?? this.e2eeSnapshot,
      pendingRemoteIce: nextPendingRemoteIce ?? pendingRemoteIce,
    );
  }

  String get formattedDuration {
    final m = durationSeconds ~/ 60;
    final s = durationSeconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  bool get isE2eeReady => e2eeSnapshot.isEncrypted;
}

class CallStateNotifier extends StateNotifier<ActiveCall?> {
  final SignalingClient _signaling;
  final void Function(PendingIncomingCall call)? onIncomingCall;
  final VoidCallback? onCallEnded;
  final VoidCallback? onIncomingCallCancelled;
  final _uuid = const Uuid();
  StreamSubscription<CallSignal>? _signalSubscription;
  Timer? _durationTimer;
  String? _currentUserId;
  bool _isTearingDown = false;

  CallStateNotifier(this._signaling, {this.onIncomingCall, this.onCallEnded, this.onIncomingCallCancelled}) : super(null) {
    _signaling.onDisconnected = _onWsDisconnected;
    unawaited(_bootstrap());
  }

  void _onWsDisconnected() {
    // When the WS drops, the signaling channel is gone.
    // Clean up any stale call state so we don't stay stuck in "busy".
    final activeCall = state;
    if (activeCall == null) return;
    // Only auto-cleanup if the call wasn't already connected (ringing/connecting).
    if (activeCall.status != CallStatus.connected) {
      _cleanupCall();
    }
  }

  void _cleanupCall() {
    final activeCall = state;
    if (activeCall == null) return;
    _stopDurationTimer();
    try { activeCall.e2ee.dispose(); } catch (_) {}
    try { activeCall.webrtc.hangup(); } catch (_) {}
    try { activeCall.networkMonitor.dispose(); } catch (_) {}
    state = null;
  }

  // Serialize signal processing: offer + iceCandidate arrive in a burst, and
  // handling them concurrently races on `state` (offer must set state before
  // iceCandidate tries to read it). Process one at a time.
  final _signalQueue = <CallSignal>[];
  bool _processingSignal = false;

  void _enqueueSignal(CallSignal signal) {
    _signalQueue.add(signal);
    if (!_processingSignal) {
      unawaited(_drainSignalQueue());
    }
  }

  Future<void> _drainSignalQueue() async {
    if (_processingSignal) return;
    _processingSignal = true;
    try {
      while (_signalQueue.isNotEmpty) {
        final signal = _signalQueue.removeAt(0);
        try {
          await _handleSignal(signal);
        } catch (e, stack) {
          debugPrint('[CALL] signal handling failed: $e\n$stack');
        }
      }
    } finally {
      _processingSignal = false;
    }
  }

  Future<void> _bootstrap() async {
    try {
      await _signaling.connect();
      _signalSubscription = _signaling.signals.listen(
        _enqueueSignal,
      );
      debugPrint('[CALL] _bootstrap: WS connected and listening');
    } catch (e, stack) {
      debugPrint('[CALL] _bootstrap FAILED: $e\n$stack');
    }
  }

  Future<void> startOutgoingCall(String contactId, String contactName) async {
    if (state != null || _isTearingDown) {
      // A previous call may still be tearing down (async WebRTC release),
      // e.g. the remote hung up and the local hangup handler is still running.
      // Wait for it to fully finish before starting a new call so we never
      // double-teardown the same WebRTC resources.
      debugPrint('[CALL] waiting for previous call teardown before new call');
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while ((state != null || _isTearingDown) && DateTime.now().isBefore(deadline)) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
      if (state != null) {
        // Still busy after waiting — force-clean to avoid a stuck call.
        final stale = state!;
        try { await stale.e2ee.dispose(); } catch (_) {}
        try { await stale.webrtc.hangup(); } catch (_) {}
        try { stale.networkMonitor.dispose(); } catch (_) {}
        state = null;
      }
      _isTearingDown = false;
    }

    final currentUserId = await _resolveCurrentUserId();
    // Resolve phone-hash (64 hex) to user UUID for signaling routing.
    final toUserId = await _resolveToUserId(contactId);
    if (toUserId == null) {
      debugPrint('[CALL] target not found for $contactId');
      throw const CallNotFoundException();
    }
    debugPrint('[CALL] startOutgoingCall currentUser=$currentUserId contactId=$contactId toUser=$toUserId');
    final callId = _uuid.v4();

    ActiveCall call;
    try {
      call = await _buildActiveCall(
        callId: callId,
        contactId: toUserId,
        contactName: contactName,
        isIncoming: false,
        currentUserId: currentUserId,
      );
    } catch (e, stack) {
      debugPrint('[CALL] _buildActiveCall failed: $e\n$stack');
      rethrow;
    }
    state = call;

    try {
      final offerHandshake = await call.e2ee.createOfferHandshake();
      final sdp = await call.webrtc.createOffer();
      call.webrtc.log('send offer to $toUserId');
      _signaling.sendOffer(
        callId: callId,
        fromUserId: currentUserId,
        toUserId: toUserId,
        sdp: sdp,
        extraPayload: {'e2ee': offerHandshake},
      );
    } catch (e, stack) {
      debugPrint('[CALL] offer creation failed: $e\n$stack');
      // Clean up on failure.
      try { await call.e2ee.dispose(); } catch (_) {}
      try { await call.webrtc.hangup(); } catch (_) {}
      state = null;
      rethrow;
    }
  }

  Future<void> acceptIncomingCall({
    required String callId,
    required String contactId,
    required String contactName,
    required String sdpOffer,
    required Map<String, dynamic> e2eeOffer,
  }) async {
    final currentUserId = await _resolveCurrentUserId();
    final call = await _buildActiveCall(
      callId: callId,
      contactId: contactId,
      contactName: contactName,
      isIncoming: true,
      currentUserId: currentUserId,
    );

    state = call;
    try {
      await call.webrtc.setRemoteDescription(sdpOffer, 'offer');
      final answerHandshake = await call.e2ee.createAnswerHandshake(e2eeOffer);
      final sdp = await call.webrtc.createAnswer();
      call.webrtc.log('send answer to $contactId');
      _signaling.sendAnswer(
        callId: callId,
        fromUserId: currentUserId,
        toUserId: contactId,
        sdp: sdp,
        extraPayload: {'e2ee': answerHandshake},
      );
      await _flushPendingIce(call);
    } catch (e) {
      call.webrtc.log('acceptIncomingCall failed: $e');
      debugPrint('[CALL] acceptIncomingCall failed: $e');
      // Clean up so we don't stay stuck in a call state.
      try { await call.e2ee.dispose(); } catch (_) {}
      try { await call.webrtc.hangup(); } catch (_) {}
      try { call.networkMonitor.dispose(); } catch (_) {}
      state = null;
      rethrow;
    }
  }

  void onCallConnected() {
    final activeCall = state;
    if (activeCall == null || activeCall.status == CallStatus.connected) {
      return;
    }
    activeCall.networkMonitor.start();
    state = activeCall.copyWith(status: CallStatus.connected);
    _startDurationTimer();
  }

  Future<void> hangup() async {
    final activeCall = state;
    if (activeCall == null) {
      return;
    }

    _stopDurationTimer();
    final status = activeCall.status == CallStatus.connected ? 'answered' : 'missed';
    // Clear state synchronously so a follow-up call isn't blocked by the
    // async teardown below.
    state = null;
    _isTearingDown = true;
    // Notify the remote side first: the local release below (DB write, E2EE
    // dispose, PeerConnection close) must not delay the hangup signal reaching
    // the callee — otherwise rapid call/end cycles leave the callee's UI stuck.
    _signaling.sendHangup(
      callId: activeCall.callId,
      fromUserId: await _resolveCurrentUserId(),
      toUserId: activeCall.contactId,
    );
    try { await _saveCallHistory(activeCall, activeCall.isIncoming ? 'incoming' : 'outgoing', status); } catch (_) {}
    try { await activeCall.e2ee.dispose(); } catch (_) {}
    try { await activeCall.webrtc.hangup(); } catch (_) {}
    try { activeCall.networkMonitor.dispose(); } catch (_) {}
    _isTearingDown = false;
    onCallEnded?.call();
  }

  Future<ActiveCall> _buildActiveCall({
    required String callId,
    required String contactId,
    required String contactName,
    required bool isIncoming,
    required String currentUserId,
  }) async {
    // 自适应 ICE：预探测当前网络 UDP 出站是否可达。
    // 可达 → p2p(ICE 先试直连，不通自动 fallback relay)；受限 → relay(经 TCP TURN)。
    final icePolicy = await determineIcePolicy(
      stunUrl: WebrtcManager.stunUrl,
      turnUrl: WebrtcManager.turnUrl,
    );
    final webrtc = WebrtcManager(policy: icePolicy);
    await webrtc.initialize();
    final monitor = NetworkMonitor(webrtc);

    late final ActiveCall activeCall;
    final e2ee = CallE2eeManager(
      callId: callId,
      localUserId: currentUserId,
      remoteUserId: contactId,
      localIsOfferer: !isIncoming,
      webrtc: webrtc,
      sendRotationPayload: (payload) async {
        // Only send if this call is still active — the rotation timer
        // may fire after hangup() if dispose() and a pending callback race.
        if (state?.callId != callId) return;
        _signaling.sendE2eeRotate(
          callId: callId,
          fromUserId: currentUserId,
          toUserId: contactId,
          payload: payload,
        );
      },
      onStateChanged: (snapshot) {
        final currentCall = state;
        if (currentCall == null || currentCall.callId != callId) {
          return;
        }
        state = currentCall.copyWith(e2eeSnapshot: snapshot);
      },
    );

    activeCall = ActiveCall(
      callId: callId,
      contactId: contactId,
      contactName: contactName,
      isIncoming: isIncoming,
      status: isIncoming ? CallStatus.connecting : CallStatus.ringing,
      startTime: DateTime.now(),
      webrtc: webrtc,
      networkMonitor: monitor,
      signaling: _signaling,
      e2ee: e2ee,
      e2eeSnapshot: e2ee.snapshot,
    );

    _wireWebrtc(activeCall, currentUserId);
    return activeCall;
  }

  void _wireWebrtc(ActiveCall activeCall, String currentUserId) {
    activeCall.webrtc.onIceCandidate = (candidate) {
      final active = state;
      if (active == null || active.callId != activeCall.callId) {
        return;
      }
      _signaling.sendIceCandidate(
        callId: active.callId,
        fromUserId: currentUserId,
        toUserId: active.contactId,
        candidate: candidate.candidate!,
        sdpMid: candidate.sdpMid!,
        sdpMLineIndex: candidate.sdpMLineIndex!,
      );
    };

    activeCall.webrtc.onConnectionState = (connectionState) {
      if (connectionState == rtc.RTCPeerConnectionState
              .RTCPeerConnectionStateConnected) {
        onCallConnected();
      }
    };

    activeCall.webrtc.onTrack = (_) {
      unawaited(activeCall.e2ee.synchronizeFrameCryptors());
    };
  }

  Future<void> _handleSignal(CallSignal signal) async {
    final payload = signal.payload ?? const <String, dynamic>{};

    switch (signal.type) {
      case CallSignalType.offer:
        if (state != null) {
          // Already in a call — send busy signal back
          _signaling.sendBusy(
            callId: signal.callId,
            fromUserId: await _resolveCurrentUserId(),
            toUserId: signal.fromUserId,
          );
          return;
        }
        final e2eeOffer = payload['e2ee'];
        if (e2eeOffer is! Map<String, dynamic>) {
          return;
        }
        // Validate the SDP before notifying the UI. A missing/malformed sdp
        // must not silently drop the incoming-call screen — always surface it.
        final sdp = payload['sdp'];
        final sdpOffer = sdp is String ? sdp : '';
        // Send ringing back FIRST — caller-name resolution (local DB or a slow
        // server lookup) must never delay ringback or drop the incoming call.
        _signaling.sendRinging(
          callId: signal.callId,
          fromUserId: await _resolveCurrentUserId(),
          toUserId: signal.fromUserId,
        );
        final contactName = await _resolveContactName(signal.fromUserId);
        // Notify UI layer about incoming call
        onIncomingCall?.call(PendingIncomingCall(
          callId: signal.callId,
          contactId: signal.fromUserId,
          contactName: contactName,
          sdpOffer: sdpOffer,
          e2eeOffer: e2eeOffer,
        ));
        break;
      case CallSignalType.answer:
        final activeCall = state;
        if (activeCall == null || activeCall.callId != signal.callId) {
          return;
        }
        // Update UI to connecting state.
        if (activeCall.status == CallStatus.ringing) {
          state = activeCall.copyWith(status: CallStatus.connecting);
        }
        activeCall.webrtc.log('recv answer, setRemoteDescription');
        await activeCall.webrtc.setRemoteDescription(
          payload['sdp'] as String,
          'answer',
        );
        final e2eeAnswer = payload['e2ee'];
        if (e2eeAnswer is Map<String, dynamic>) {
          try {
            await activeCall.e2ee.completeWithAnswer(e2eeAnswer);
            activeCall.webrtc.log('E2EE answer complete');
          } catch (e) {
            activeCall.webrtc.log('E2EE answer failed: $e');
            debugPrint('[CALL] e2ee answer failed: $e');
            // Abort the call cleanly — no silent one-way audio.
            await hangup();
            return;
          }
        }
        await _flushPendingIce(activeCall);
        break;
      case CallSignalType.iceCandidate:
        final activeCall = state;
        if (activeCall == null || activeCall.callId != signal.callId) {
          return;
        }
        final candidate = <String, Object?>{
          'candidate': payload['candidate'] as String,
          'sdp_mid': payload['sdp_mid'] as String,
          'sdp_m_line_index': payload['sdp_m_line_index'] as int,
        };
        if (await activeCall.webrtc.peerConnection?.getRemoteDescription() ==
            null) {
          activeCall.pendingRemoteIce.add(candidate);
          return;
        }
        activeCall.webrtc.log('recv remote ICE: ${CallDiagnostics.typeOf(payload['candidate'] as String)}');
        await _addIceCandidate(activeCall, candidate);
        break;
      case CallSignalType.e2eeRotate:
        final activeCall = state;
        if (activeCall == null || activeCall.callId != signal.callId) {
          return;
        }
        await activeCall.e2ee.handleRotation(payload);
        break;
      case CallSignalType.hangup:
        final activeCall = state;
        if (activeCall == null || activeCall.callId != signal.callId) {
          // Caller hung up before we accepted — dismiss the incoming screen.
          if (activeCall == null) {
            onIncomingCallCancelled?.call();
          }
          return;
        }
        activeCall.webrtc.log('recv hangup');
        // Clear the state synchronously so an immediate new call sees no stale
        // call, then release resources in the background.
        _stopDurationTimer();
        state = null;
        _isTearingDown = true;
        try {
          await _saveCallHistory(activeCall, 'incoming', 'answered');
        } catch (_) {}
        try { await activeCall.e2ee.dispose(); } catch (_) {}
        try { await activeCall.webrtc.hangup(); } catch (_) {}
        try { activeCall.networkMonitor.dispose(); } catch (_) {}
        _isTearingDown = false;
        onCallEnded?.call();
        break;
      case CallSignalType.ringing:
        final activeCall = state;
        if (activeCall == null || activeCall.callId != signal.callId) {
          return;
        }
        if (activeCall.status != CallStatus.ringing) {
          state = activeCall.copyWith(status: CallStatus.ringing);
        }
        break;
      case CallSignalType.busy:
        // Remote party declined — end this call
        await hangup();
        break;
    }
  }

  Future<void> _flushPendingIce(ActiveCall activeCall) async {
    for (final candidate in activeCall.pendingRemoteIce) {
      await _addIceCandidate(activeCall, candidate);
    }
    activeCall.pendingRemoteIce.clear();
  }

  Future<void> _addIceCandidate(
    ActiveCall activeCall,
    Map<String, Object?> candidate,
  ) async {
    await activeCall.webrtc.addIceCandidate(
      candidate['candidate']! as String,
      candidate['sdp_mid']! as String,
      candidate['sdp_m_line_index']! as int,
    );
  }

  Future<String> _resolveCurrentUserId() async {
    if (_currentUserId != null) {
      return _currentUserId!;
    }
    _currentUserId = await AuthGuard.getUserId() ?? 'unknown';
    return _currentUserId!;
  }

  /// Resolve a contact identifier to a signaling user ID.
  /// Phone hashes (64 hex chars) are looked up via the server; UUIDs (32 hex) pass through.
  /// Raw phone numbers are hashed first then looked up.
  static final _phoneHashRe = RegExp(r'^[0-9a-f]{64}$');
  static final _uuidRe = RegExp(r'^[0-9a-f]{32}$');
  Future<String?> _resolveToUserId(String contactId) async {
    // If it's already a server user UUID (e.g. from call history), pass through.
    if (_uuidRe.hasMatch(contactId)) {
      debugPrint('[CALL] _resolveToUserId: contactId is a UUID, pass through: $contactId');
      return contactId;
    }
    final client = ApiClient();
    try {
      final String hashToLookup;
      if (_phoneHashRe.hasMatch(contactId)) {
        hashToLookup = contactId;
      } else {
        // Could be a raw phone number or a UUID.
        // If it looks like a phone number, hash it with the server-matching salt.
        hashToLookup = CryptoManager.sha256Hash(contactId, salt: 'myphone-salt:');
      }
      debugPrint('[CALL] _resolveToUserId: contactId=$contactId lookupHash=$hashToLookup');
      final userId = await client.lookupUserByPhoneHash(hashToLookup);
      if (userId != null) {
        debugPrint('[CALL] _resolveToUserId: resolved to $userId');
        return userId;
      }
    } catch (e) {
      debugPrint('[CALL] _resolveToUserId lookup failed: $e');
    } finally {
      client.dispose();
    }
    // No registered user found for this phone number → signal "not found".
    return null;
  }

  /// Resolve a user UUID to a human-readable name.
  ///
  /// Runs on the incoming-call path before the UI is notified, so it must
  /// never throw (a DB failure) or hang (a slow server): both would silently
  /// drop the incoming call. Every failure falls through to the next source.
  Future<String> _resolveContactName(String userId) async {
    // 1. Try local contacts DB first.
    try {
      final row = await DatabaseManager.instance.getContact(userId);
      if (row != null && row['display_name'] is String && (row['display_name'] as String).isNotEmpty) {
        return row['display_name'] as String;
      }
    } catch (e) {
      debugPrint('[CALL] local contact lookup failed: $e');
    }
    // 2. Try server-side user lookup, bounded by a timeout so a slow server
    // can't delay the incoming-call screen.
    final client = ApiClient();
    try {
      final info = await client.lookupUserById(userId).timeout(const Duration(seconds: 3));
      if (info != null) {
        final name = info['display_name'] as String?;
        if (name != null && name.isNotEmpty) return name;
        final hash = info['phone_hash'] as String?;
        if (hash != null) return '(Phone hash: ${hash.substring(0, 8)}...)';
      }
    } catch (_) {
    } finally {
      client.dispose();
    }
    // 3. Fallback to a short UUID prefix.
    return userId.length > 8 ? 'User ${userId.substring(0, 8)}' : userId;
  }

  Future<void> _saveCallHistory(ActiveCall call, String direction, String status) async {
    try {
      await DatabaseManager.instance.insertCallHistory({
        'id': call.callId,
        'contact_id': call.contactId,
        'contact_name': call.contactName,
        'direction': direction,
        'status': status,
        'duration_seconds': call.durationSeconds,
        'call_type': 'audio',
        'started_at': call.startTime.millisecondsSinceEpoch,
        'ended_at': DateTime.now().millisecondsSinceEpoch,
      });
      debugPrint('[CALL] history saved: $direction/$status/${call.durationSeconds}s');
    } catch (e) {
      debugPrint('[CALL] history save failed: $e');
    }
  }

  void _startDurationTimer() {
    _durationTimer?.cancel();
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final activeCall = state;
      if (activeCall == null || activeCall.status != CallStatus.connected) {
        return;
      }
      state = activeCall.copyWith(
        durationSeconds: activeCall.durationSeconds + 1,
      );
    });
  }

  void _stopDurationTimer() {
    _durationTimer?.cancel();
    _durationTimer = null;
  }

  @override
  void dispose() {
    _stopDurationTimer();
    _signalSubscription?.cancel();
    _signaling.dispose();
    super.dispose();
  }

  /// Sends busy signal for a pending incoming call (called from UI before
  /// the call has been accepted).
  Future<void> declineIncomingCall(PendingIncomingCall info) async {
    final currentUserId = await _resolveCurrentUserId();
    _signaling.sendBusy(
      callId: info.callId,
      fromUserId: currentUserId,
      toUserId: info.contactId,
    );
  }
}

final callStateProvider = StateNotifierProvider<CallStateNotifier, ActiveCall?>(
  (ref) => CallStateNotifier(
    createSignalingClient(),
    onIncomingCall: (call) {
      ref.read(incomingCallProvider.notifier).setIncoming(call);
    },
    onCallEnded: () {
      ref.read(callCountProvider.notifier).state++;
    },
    onIncomingCallCancelled: () {
      ref.read(incomingCallProvider.notifier).clear();
    },
  ),
);

/// Incremented each time a call ends — used to trigger history refresh.
final callCountProvider = StateProvider<int>((ref) => 0);
