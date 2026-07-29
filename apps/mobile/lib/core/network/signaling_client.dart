/// WebSocket signaling client for call setup and teardown.
/// Exchanges: SDP offers/answers, ICE candidates, call state transitions.
/// The server only relays encrypted signaling data and never sees plaintext.
library;

import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../../app/auth_guard.dart';
import 'server_config.dart';

enum CallSignalType {
  offer,
  answer,
  iceCandidate,
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

  Stream<CallSignal> get signals => _signalController.stream;

  Future<void> connect() async {
    final token = await AuthGuard.getToken();
    _channel = WebSocketChannel.connect(Uri.parse('$_baseUrl?token=$token'));

    _channel!.stream.listen(
      (data) {
        final json = jsonDecode(data as String) as Map<String, dynamic>;
        _signalController.add(CallSignal.fromJson(json));
      },
      onError: (_) {},
      onDone: () {},
    );

    _pingTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _channel?.sink.add(jsonEncode({'type': 'ping'}));
    });
  }

  void sendSignal(CallSignal signal) {
    _channel?.sink.add(jsonEncode(signal.toJson()));
  }

  void sendOffer({
    required String callId,
    required String fromUserId,
    required String toUserId,
    required String sdp,
  }) {
    sendSignal(CallSignal(
      type: CallSignalType.offer,
      callId: callId,
      fromUserId: fromUserId,
      toUserId: toUserId,
      payload: {'sdp': sdp},
    ));
  }

  void sendAnswer({
    required String callId,
    required String fromUserId,
    required String toUserId,
    required String sdp,
  }) {
    sendSignal(CallSignal(
      type: CallSignalType.answer,
      callId: callId,
      fromUserId: fromUserId,
      toUserId: toUserId,
      payload: {'sdp': sdp},
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

  void dispose() {
    _pingTimer?.cancel();
    _signalController.close();
    _channel?.sink.close();
  }
}
