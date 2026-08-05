/// WebSocket signaling client for call setup and teardown.
/// Exchanges: SDP offers/answers, ICE candidates, call state transitions.
/// Signaling payloads are currently relayed as plain JSON over the app socket.
library;

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../../app/auth_guard.dart';
import 'server_config.dart';

enum CallSignalType {
  offer,
  answer,
  iceCandidate,
  e2eeRotate,
  hangup,
  busy,
  ringing,
}

class CallSignal {
  final CallSignalType type;
  final String callId;
  final String fromUserId;
  final String toUserId;
  final Map<String, dynamic>? payload;

  CallSignal({
    required this.type,
    required this.callId,
    required this.fromUserId,
    required this.toUserId,
    this.payload,
  });

  Map<String, dynamic> toJson() => {
        'type': type.name,
        'call_id': callId,
        'from_user_id': fromUserId,
        'to_user_id': toUserId,
        'payload': payload ?? {},
      };

  factory CallSignal.fromJson(Map<String, dynamic> json) => CallSignal(
        type: CallSignalType.values.firstWhere((e) => e.name == json['type']),
        callId: json['call_id'],
        fromUserId: json['from_user_id'],
        toUserId: json['to_user_id'],
        payload: json['payload'] as Map<String, dynamic>?,
      );
}

class SignalingClient {
  final String _baseUrl = ServerConfig.wsEndpoint;
  WebSocketChannel? _channel;
  final _signalController = StreamController<CallSignal>.broadcast();
  Timer? _pingTimer;
  Timer? _reconnectTimer;
  VoidCallback? _onDisconnected;
  set onDisconnected(VoidCallback? cb) => _onDisconnected = cb;
  int _reconnectAttempts = 0;
  bool _disposed = false;

  Stream<CallSignal> get signals => _signalController.stream;

  Future<void> connect() async {
    await _doConnect();
  }

  Future<void> _doConnect() async {
    if (_disposed) return;
    // Close old channel before creating a new one.
    _channel?.sink.close();
    _channel = null;
    final token = await AuthGuard.getToken();
    if (token == null) return;
    final wsUrl = '$_baseUrl?token=$token';
    debugPrint('[SIGNAL] connecting to $wsUrl');
    _channel = WebSocketChannel.connect(Uri.parse(wsUrl));
    // Reset backoff as soon as we (re)establish the connection, so a healthy
    // link never drifts toward long reconnect delays.
    _reconnectAttempts = 0;

    _channel!.stream.listen(
      (data) {
        final json = jsonDecode(data as String) as Map<String, dynamic>;
        debugPrint('[SIGNAL] recv ${json['type']} callId=${json['call_id']} from=${json['from_user_id']}');
        _signalController.add(CallSignal.fromJson(json));
      },
      onError: (e) {
        debugPrint('[SIGNAL] ws error: $e');
        _onWsClosed();
      },
      onDone: () {
        debugPrint('[SIGNAL] ws closed');
        _onWsClosed();
      },
    );

    _pingTimer?.cancel();
    // Heartbeat every 15s to keep NAT/proxy mappings alive and detect dead
    // connections quickly.  The server's read deadline is 60s, so 15s pings
    // are well within budget and survive transient gaps.
    _pingTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      try {
        _channel?.sink.add(jsonEncode({'type': 'ping'}));
      } catch (_) {
        // Channel is dead — force a reconnect.
        _onWsClosed();
      }
    });
  }

  void _onWsClosed() {
    if (_disposed) return;
    _pingTimer?.cancel();
    _channel = null;
    _onDisconnected?.call();

    // Reconnect with backoff: 2s, 4s, 8s, 16s, 30s max
    final delay = (_reconnectAttempts < 5)
        ? Duration(seconds: 1 << (_reconnectAttempts + 1))
        : const Duration(seconds: 30);
    _reconnectAttempts++;
    debugPrint('[SIGNAL] reconnect in ${delay.inSeconds}s (attempt $_reconnectAttempts)');
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, _doConnect);
  }

  void sendSignal(CallSignal signal) {
    final data = jsonEncode(signal.toJson());
    debugPrint('[SIGNAL] send type=${signal.type.name} to=${signal.toUserId} callId=${signal.callId}');
    _channel?.sink.add(data);
  }

  void sendOffer({
    required String callId,
    required String fromUserId,
    required String toUserId,
    required String sdp,
    Map<String, dynamic>? extraPayload,
  }) {
    sendSignal(CallSignal(
      type: CallSignalType.offer,
      callId: callId,
      fromUserId: fromUserId,
      toUserId: toUserId,
      payload: {
        'sdp': sdp,
        ...?extraPayload,
      },
    ));
  }

  void sendAnswer({
    required String callId,
    required String fromUserId,
    required String toUserId,
    required String sdp,
    Map<String, dynamic>? extraPayload,
  }) {
    sendSignal(CallSignal(
      type: CallSignalType.answer,
      callId: callId,
      fromUserId: fromUserId,
      toUserId: toUserId,
      payload: {
        'sdp': sdp,
        ...?extraPayload,
      },
    ));
  }

  void sendIceCandidate({
    required String callId,
    required String fromUserId,
    required String toUserId,
    required String candidate,
    required String sdpMid,
    required int sdpMLineIndex,
  }) {
    sendSignal(CallSignal(
      type: CallSignalType.iceCandidate,
      callId: callId,
      fromUserId: fromUserId,
      toUserId: toUserId,
      payload: {
        'candidate': candidate,
        'sdp_mid': sdpMid,
        'sdp_m_line_index': sdpMLineIndex,
      },
    ));
  }

  void sendHangup({
    required String callId,
    required String fromUserId,
    required String toUserId,
  }) {
    sendSignal(CallSignal(
      type: CallSignalType.hangup,
      callId: callId,
      fromUserId: fromUserId,
      toUserId: toUserId,
    ));
  }

  void sendRinging({
    required String callId,
    required String fromUserId,
    required String toUserId,
  }) {
    sendSignal(CallSignal(
      type: CallSignalType.ringing,
      callId: callId,
      fromUserId: fromUserId,
      toUserId: toUserId,
    ));
  }

  void sendBusy({
    required String callId,
    required String fromUserId,
    required String toUserId,
  }) {
    sendSignal(CallSignal(
      type: CallSignalType.busy,
      callId: callId,
      fromUserId: fromUserId,
      toUserId: toUserId,
    ));
  }

  void sendE2eeRotate({
    required String callId,
    required String fromUserId,
    required String toUserId,
    required Map<String, dynamic> payload,
  }) {
    sendSignal(CallSignal(
      type: CallSignalType.e2eeRotate,
      callId: callId,
      fromUserId: fromUserId,
      toUserId: toUserId,
      payload: payload,
    ));
  }

  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _pingTimer?.cancel();
    _signalController.close();
    _channel?.sink.close();
  }
}
