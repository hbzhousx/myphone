/// 聊天信令信封：复用与通话相同的 `{type, from_user_id, to_user_id, payload}` 形状，
/// 服务器中继零改动即可透传（hub 只认 to_user_id 转发；chatMessage 额外走离线队列）。
library;

enum ChatSignalType {
  chatInit,
  chatMessage,
  chatReceipt,
  chatTyping,
  chatDisappearing,
  chatFileOffer,
  chatFileAnswer,
  chatFileIce,
  chatFileDone,
  chatDiag,
  chatAttachment,

  // ---- v1.50 AI 语音通话（哪吒/智能体）----
  // agentInit: 客户端→bot，{session_id}
  // agentSignal: 双向，{session_id, signal:{type,sdp,candidate,...}} SDP/ICE 中继
  // agentHangup: 双向，{session_id}
  // agentReady: bot→客户端，{state:'connected'|'listening'|'speaking'|'ended', reason?}
  // agentTranscript: bot→客户端，字幕 {seq, who:'user'|'agent', text, is_final}
  agentInit,
  agentSignal,
  agentHangup,
  agentReady,
  agentTranscript,
  // agentSpeech: bot→客户端，用户说话状态 {speaking: bool}（麦克风动态图标）
  agentSpeech,
}

class ChatSignal {
  final ChatSignalType type;
  final String fromUserId;
  final String toUserId;
  final String? messageId;
  final Map<String, dynamic>? payload;

  const ChatSignal({
    required this.type,
    required this.fromUserId,
    required this.toUserId,
    this.messageId,
    this.payload,
  });

  Map<String, dynamic> toJson() => {
        'type': type.name,
        'from_user_id': fromUserId,
        'to_user_id': toUserId,
        if (messageId != null) 'message_id': messageId,
        'payload': payload ?? {},
      };

  factory ChatSignal.fromJson(Map<String, dynamic> json) => ChatSignal(
        type: ChatSignalType.values.firstWhere((e) => e.name == json['type']),
        fromUserId: json['from_user_id'] as String,
        toUserId: json['to_user_id'] as String,
        messageId: json['message_id'] as String?,
        payload: json['payload'] as Map<String, dynamic>?,
      );

  /// 所有聊天类型名（供 WS 分发判断）。
  static final Set<String> typeNames = {
    for (final t in ChatSignalType.values) t.name,
  };
}
