/// Call state management using Riverpod.
library;

import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../core/webrtc/webrtc_manager.dart';
import '../../core/webrtc/network_monitor.dart';
import '../../core/network/signaling_client.dart';

enum CallStatus { idle, ringing, connecting, connected, ended }

class ActiveCall {
  final String callId;
  final String contactId;
  final String contactName;
  final bool isIncoming;
  CallStatus status;
  final DateTime startTime;
  DateTime? endTime;
  int durationSeconds;
  Timer? durationTimer;
  final WebrtcManager webrtc;
  final NetworkMonitor networkMonitor;
  final SignalingClient signaling;

  ActiveCall({
    required this.callId,
    required this.contactId,
    required this.contactName,
    required this.isIncoming,
    required this.status,
    required this.startTime,
    required this.webrtc,
    required this.networkMonitor,
    required this.signaling,
    this.durationSeconds = 0,
  });

  void startDurationTimer() {
    durationTimer = Timer.periodic(const Duration(seconds: 1), (_) => durationSeconds++);
  }

  void end() {
    durationTimer?.cancel();
    status = CallStatus.ended;
    endTime = DateTime.now();
  }

  String get formattedDuration {
    final m = durationSeconds ~/ 60;
    final s = durationSeconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
}

class CallStateNotifier extends StateNotifier<ActiveCall?> {
  final SignalingClient _signaling;
  final _uuid = const Uuid();

  CallStateNotifier(this._signaling) : super(null);

  Future<void> startOutgoingCall(String contactId, String contactName) async {
    final callId = _uuid.v4();
    final webrtc = WebrtcManager();
    await webrtc.initialize();
    final monitor = NetworkMonitor(webrtc);

    state = ActiveCall(
      callId: callId, contactId: contactId, contactName: contactName,
      isIncoming: false, status: CallStatus.ringing, startTime: DateTime.now(),
      webrtc: webrtc, networkMonitor: monitor, signaling: _signaling,
    );

    final sdp = await webrtc.createOffer();
    _signaling.sendOffer(callId: callId, fromUserId: 'current-user', toUserId: contactId, sdp: sdp);
  }

  Future<void> acceptIncomingCall({
    required String callId, required String contactId,
    required String contactName, required String sdpOffer,
  }) async {
    final webrtc = WebrtcManager();
    await webrtc.initialize();
    final monitor = NetworkMonitor(webrtc);

    state = ActiveCall(
      callId: callId, contactId: contactId, contactName: contactName,
      isIncoming: true, status: CallStatus.connecting, startTime: DateTime.now(),
      webrtc: webrtc, networkMonitor: monitor, signaling: _signaling,
    );

    await webrtc.setRemoteDescription(sdpOffer, 'offer');
    final sdp = await webrtc.createAnswer();
    _signaling.sendAnswer(callId: callId, fromUserId: 'current-user', toUserId: contactId, sdp: sdp);
  }

  void onCallConnected() {
    if (state == null) return;
    state!.status = CallStatus.connected;
    state!.networkMonitor.start();
    state!.startDurationTimer();
    state = state;
  }

  void hangup() {
    if (state == null) return;
    state!.end();
    state!.webrtc.hangup();
    state!.networkMonitor.dispose();
    _signaling.sendHangup(callId: state!.callId, fromUserId: 'current-user', toUserId: state!.contactId);
    state = null;
  }
}

final callStateProvider = StateNotifierProvider<CallStateNotifier, ActiveCall?>(
  (ref) => CallStateNotifier(SignalingClient()),
);
