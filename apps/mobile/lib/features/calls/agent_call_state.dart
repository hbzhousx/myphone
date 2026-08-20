/// AI 语音通话（哪吒/智能体）状态管理 —— v1.50。
///
/// 与真实通话（[callStateProvider]）互斥：启动前由界面检查；会话中收到真实
/// 来电（`signals` 流出现 offer）→ 自动挂 AI 会话，让位给来电。
///
/// ★WS 必须单例：复用 [createSignalingClient] 的单例信令通道，只订阅
/// chatSignals / signals 流，**绝不 connect()**（第二条 WS 会互踢）。
///
/// 与智能体的对话不需要加密：整条 Agent 链路明文（agentInit/agentSignal/
/// agentHangup/agentReady/agentTranscript 均不经 X3DH）；聊天历史回流复用
/// bot 明文旁路（chatMessage plaintext:true）。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:permission_handler/permission_handler.dart';
import 'package:uuid/uuid.dart';

import '../../app/auth_guard.dart';
import '../../core/network/chat_signal.dart';
import '../../core/network/service_bridge.dart';
import '../../core/network/signaling_client.dart';
import '../../core/webrtc/webrtc_manager.dart';
import 'call_state.dart';

enum AgentCallStatus { idle, connecting, connected, ended }

/// AI 会话的一条实时字幕（agentTranscript）。
class AgentTranscript {
  final int seq;
  final String who; // 'user' | 'agent'
  final String text;
  final bool isFinal;
  const AgentTranscript({
    required this.seq,
    required this.who,
    required this.text,
    required this.isFinal,
  });
}

class AgentCallState {
  final String sessionId;
  final String contactId; // 服务端 bot 用户 id（bot-luozha）
  final String contactName;
  final AgentCallStatus status;
  final List<AgentTranscript> transcripts;
  final String? statusText; // agentReady 状态机补充（listening/speaking/...）

  const AgentCallState({
    required this.sessionId,
    required this.contactId,
    required this.contactName,
    required this.status,
    this.transcripts = const [],
    this.statusText,
  });

  AgentCallState copyWith({
    AgentCallStatus? status,
    List<AgentTranscript>? transcripts,
    String? statusText,
  }) {
    return AgentCallState(
      sessionId: sessionId,
      contactId: contactId,
      contactName: contactName,
      status: status ?? this.status,
      transcripts: transcripts ?? this.transcripts,
      statusText: statusText ?? this.statusText,
    );
  }
}

class AgentCallStateNotifier extends StateNotifier<AgentCallState?> {
  final SignalingClient _signaling;
  final _uuid = const Uuid();

  StreamSubscription<ChatSignal>? _chatSub;
  StreamSubscription<CallSignal>? _callSub;
  WebrtcManager? _webrtc;
  String? _currentUserId;
  final List<Map<String, Object?>> _pendingIce = [];

  // 会话内已处理的 agentTranscript seq，避免重复追加。
  int _lastTranscriptSeq = -1;

  AgentCallStateNotifier(this._signaling) : super(null) {
    // 订阅聊天信令流（AI 会话信令走 chatSignals）。
    _chatSub = _signaling.chatSignals.listen(_handleChatSignal);
    // 订阅通话信令流：AI 会话中收到真实来电（offer）→ 自动挂断让位。
    _callSub = _signaling.signals.listen((signal) {
      if (signal.type == CallSignalType.offer && state != null) {
        debugPrint('[AGENT-CALL] real incoming call during AI session — hang up');
        unawaited(hangup());
      }
    });
  }

  bool get isMuted => _webrtc?.isMuted ?? false;
  bool get isSpeakerOn => _webrtc?.isSpeakerOn ?? false;

  void toggleMute() => _webrtc?.toggleMute();
  Future<void> toggleSpeaker() async {
    await _webrtc?.toggleSpeaker();
  }

  /// 发起 AI 语音会话：发 agentInit → 建 PeerConnection → 发 offer。
  /// 界面临终调用；contactId 为 bot 用户 id（bot-luozha）。
  Future<void> start({required String contactId, required String contactName}) async {
    final existing = state;
    if (existing != null) return;

    final sessionId = _uuid.v4();
    final currentUserId = await _resolveCurrentUserId();

    // ★请求麦克风权限：普通通话(CallScreen)有权限请求，AI 通话此前没有 →
    //   getUserMedia 拿到静音流 → 手机说话对方听不到。必须显式请求。
    var micStatus = await Permission.microphone.status;
    if (!micStatus.isGranted) {
      micStatus = await Permission.microphone.request();
    }
    if (!micStatus.isGranted) {
      debugPrint('[AGENT-CALL] microphone permission denied: $micStatus');
      throw StateError('microphone permission denied');
    }

    final webrtc = WebrtcManager();
    await webrtc.initialize();
    // 默认听筒（非扬声器），降低回声。
    await webrtc.setSpeakerOn(false);
    _webrtc = webrtc;
    _lastTranscriptSeq = -1;
    _pendingIce.clear();

    // 本地 ICE 候选 → agentSignal{ice} 发给媒体端点。
    webrtc.onIceCandidate = (candidate) {
      _sendAgentSignal(sessionId, {
        'type': 'ice',
        'candidate': candidate.candidate,
        'sdp_mid': candidate.sdpMid,
        'sdp_m_line_index': candidate.sdpMLineIndex,
      });
    };
    webrtc.onConnectionState = (rtcState) {
      if (rtcState == rtc.RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        final s = state;
        if (s != null && s.sessionId == sessionId && s.status != AgentCallStatus.connected) {
          state = s.copyWith(status: AgentCallStatus.connected);
        }
      }
    };

    state = AgentCallState(
      sessionId: sessionId,
      contactId: contactId,
      contactName: contactName,
      status: AgentCallStatus.connecting,
      statusText: '连接中…',
    );

    try {
      // 发 agentInit 告知媒体端点新会话。
      await _sendChatSignal(ChatSignalType.agentInit, contactId, {
        'session_id': sessionId,
      });
      final sdp = await webrtc.createOffer();
      _sendAgentSignal(sessionId, {'type': 'offer', 'sdp': sdp});
      debugPrint('[AGENT-CALL] start session=$sessionId offer sent');
    } catch (e, stack) {
      debugPrint('[AGENT-CALL] start failed: $e\n$stack');
      await hangup();
    }
  }

  /// 挂断 AI 会话：发 agentHangup + 释放媒体 + 状态清空。
  Future<void> hangup() async {
    final s = state;
    if (s == null) return;
    final webrtc = _webrtc;
    state = null;
    _webrtc = null;
    _pendingIce.clear();
    _lastTranscriptSeq = -1;
    try {
      await _sendChatSignal(ChatSignalType.agentHangup, s.contactId, {
        'session_id': s.sessionId,
      });
    } catch (_) {}
    try { await webrtc?.hangup(); } catch (_) {}
    debugPrint('[AGENT-CALL] hangup session=${s.sessionId}');
  }

  /// 处理入站 AI 会话信令（按类型 + session_id 过滤）。
  Future<void> _handleChatSignal(ChatSignal signal) async {
    final s = state;
    if (s == null) return;
    final payload = signal.payload ?? const <String, dynamic>{};
    if (payload['session_id'] != s.sessionId) return;

    switch (signal.type) {
      case ChatSignalType.agentSignal:
        final sig = payload['signal'];
        if (sig is! Map<String, dynamic>) return;
        await _handleAgentSignal(s, sig);
        break;
      case ChatSignalType.agentReady:
        final readyState = payload['state'] as String? ?? '';
        final reason = payload['reason'] as String?;
        debugPrint('[AGENT-CALL] agentReady state=$readyState reason=$reason');
        if (readyState == 'ended') {
          await hangup();
        } else if (readyState == 'connected') {
          state = s.copyWith(status: AgentCallStatus.connected, statusText: '已连接');
        } else {
          state = s.copyWith(statusText: _readyLabel(readyState));
        }
        break;
      case ChatSignalType.agentTranscript:
        final seq = (payload['seq'] as num?)?.toInt() ?? -1;
        if (seq <= _lastTranscriptSeq) return; // 乱序/重投去重
        _lastTranscriptSeq = seq;
        final who = payload['who'] as String? ?? 'agent';
        final text = payload['text'] as String? ?? '';
        final isFinal = payload['is_final'] == true;
        if (text.isEmpty) return;
        final transcripts = [...s.transcripts, AgentTranscript(seq: seq, who: who, text: text, isFinal: isFinal)];
        if (transcripts.length > 200) transcripts.removeRange(0, transcripts.length - 200);
        state = s.copyWith(transcripts: transcripts);
        break;
      case ChatSignalType.agentHangup:
        // 媒体端点主动结束。
        await hangup();
        break;
      default:
        break;
    }
  }

  Future<void> _handleAgentSignal(AgentCallState s, Map<String, dynamic> sig) async {
    final webrtc = _webrtc;
    if (webrtc == null) return;
    final type = sig['type'] as String?;
    switch (type) {
      case 'answer':
        await webrtc.setRemoteDescription(sig['sdp'] as String, 'answer');
        for (final ice in _pendingIce) {
          await webrtc.addIceCandidate(
            ice['candidate']! as String,
            ice['sdp_mid']! as String,
            ice['sdp_m_line_index']! as int,
          );
        }
        _pendingIce.clear();
        if (s.status != AgentCallStatus.connected) {
          state = s.copyWith(status: AgentCallStatus.connected, statusText: '已连接');
        }
        break;
      case 'ice':
        final candidate = <String, Object?>{
          'candidate': sig['candidate'] as String,
          'sdp_mid': sig['sdp_mid'] as String,
          'sdp_m_line_index': sig['sdp_m_line_index'] as int,
        };
        if (await webrtc.peerConnection?.getRemoteDescription() == null) {
          _pendingIce.add(candidate);
          return;
        }
        await webrtc.addIceCandidate(
          candidate['candidate']! as String,
          candidate['sdp_mid']! as String,
          candidate['sdp_m_line_index']! as int,
        );
        break;
    }
  }

  void _sendAgentSignal(String sessionId, Map<String, dynamic> signal) {
    final s = state;
    if (s == null) return;
    _sendChatSignal(ChatSignalType.agentSignal, s.contactId, {
      'session_id': sessionId,
      'signal': signal,
    });
  }

  Future<bool> _sendChatSignal(ChatSignalType type, String toUserId, Map<String, dynamic> payload) {
    final userId = _currentUserId ?? 'unknown';
    return _signaling.sendChatSignal(ChatSignal(
      type: type,
      fromUserId: userId,
      toUserId: toUserId,
      payload: payload,
    ));
  }

  Future<String> _resolveCurrentUserId() async {
    _currentUserId ??= await AuthGuard.getUserId() ?? 'unknown';
    return _currentUserId!;
  }

  static String _readyLabel(String state) => switch (state) {
        'listening' => '聆听中…',
        'speaking' => '说话中…',
        'connected' => '已连接',
        _ => state,
      };

  @override
  void dispose() {
    _chatSub?.cancel();
    _callSub?.cancel();
    try { _webrtc?.hangup(); } catch (_) {}
    super.dispose();
  }
}

/// AI 会话全局状态（与 callStateProvider 互斥；两者不会同时非空）。
final agentCallStateProvider =
    StateNotifierProvider<AgentCallStateNotifier, AgentCallState?>(
  (ref) => AgentCallStateNotifier(createSignalingClient()),
);
