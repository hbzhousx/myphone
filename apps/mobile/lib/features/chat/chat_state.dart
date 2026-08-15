/// 聊天全局状态：持有信令订阅、按会话分发入站信号、管理会话控制器。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/auth_guard.dart';
import '../../core/crypto/chat_session_manager.dart';
import '../../core/network/api_client.dart';
import '../../core/network/chat_signal.dart';
import '../../core/network/service_bridge.dart';
import '../../core/network/signaling_client.dart';
import '../../core/storage/database.dart';
import 'chat_session_controller.dart';

class ChatState {
  /// 当前打开的会话（conversationId），用于定向分发。
  final String? activeConversationId;
  final bool connected;

  const ChatState({this.activeConversationId, this.connected = true});

  ChatState copyWith({String? activeConversationId, bool? connected}) =>
      ChatState(
        activeConversationId: activeConversationId ?? this.activeConversationId,
        connected: connected ?? this.connected,
      );
}

class ChatStateNotifier extends StateNotifier<ChatState> {
  final SignalingClient _signaling;
  final DatabaseManager _db;
  final ChatSessionManager _sessions;

  StreamSubscription<ChatSignal>? _chatSub;
  Timer? _expiryTimer;
  String? _localUserId;

  /// 会话控制器缓存（conversationId → controller）。
  final Map<String, ChatSessionController> _controllers = {};

  ChatStateNotifier({
    required SignalingClient signaling,
    required DatabaseManager db,
    required ChatSessionManager sessions,
  })  : _signaling = signaling,
        _db = db,
        _sessions = sessions,
        super(const ChatState()) {
    _init().whenComplete(_completeReady);
  }

  Future<void> _init() async {
    try {
      _localUserId = await AuthGuard.getUserId() ?? '';
      _diag('init:userId', {'id': _localUserId ?? ''});
    } catch (e) {
      _localUserId = '';
      _diag('init:userId-fail', {'err': '$e'});
    }
    try {
      await _sessions.publishPrekeyBundle();
      _diag('init:prekey-ok', {});
    } catch (e) {
      // 发布失败（未登录/网络）不阻塞聊天，会话建立时会重试。打日志便于定位。
      debugPrint('[CHAT-STATE] publishPrekeyBundle failed: $e');
      _diag('init:prekey-fail', {'err': '$e'});
    }
    try {
      await _signaling.connect();
      _diag('init:connect-ok', {});
    } catch (e) {
      // 连接失败不阻塞：常驻桥接模式下由服务自愈重连。
      _diag('init:connect-fail', {'err': '$e'});
    }
    _chatSub = _signaling.chatSignals.listen(_onChatSignal);
    _diag('init:done', {});
    _expiryTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      final n = await _db.deleteExpiredMessages();
      if (n > 0) {
        // 诊断：阅后即焚删除发生时上报（定位"消息莫名消失"）。走 _diag 统一开关。
        _diag('expiry:deleted', {'count': n});
      }
    });
    _db.deleteExpiredMessages();
  }

  /// _init 完成信号：controllerFor 等待 _localUserId 就绪，避免 from_user_id 为空。
  Future<void> get ready => _readyCompleter.future;
  final Completer<void> _readyCompleter = Completer<void>();

  /// 无论 _init 是否抛异常，都完成 ready，防止 controllerFor 死锁。
  void _completeReady() {
    if (!_readyCompleter.isCompleted) _readyCompleter.complete();
  }

  /// 当前打开会话（由 UI 进入聊天页时调用）。
  void setActiveConversation(String? conversationId) {
    state = state.copyWith(activeConversationId: conversationId);
  }

  /// 诊断上报（fire-and-forget，不阻塞 _init）。
  void _diag(String step, Map<String, dynamic> data) {
    if (!kChatDiag) return;
    try {
      _signaling.sendChatSignal(ChatSignal(
        type: ChatSignalType.chatDiag,
        fromUserId: _localUserId ?? '',
        toUserId: _localUserId ?? '',
        payload: {'step': step, ...data},
      ));
    } catch (_) {}
  }

  /// 获取（或懒建）某会话的控制器。等待 _init 完成以确保 _localUserId 非空。
  Future<ChatSessionController> controllerFor({
    required String remoteUserId,
    required String conversationId,
  }) async {
    await ready;
    return _controllers.putIfAbsent(conversationId, () => ChatSessionController(
          db: _db,
          sessions: _sessions,
          signaling: _signaling,
          localUserId: _localUserId ?? '',
          remoteUserId: remoteUserId,
          conversationId: conversationId,
        ));
  }

  Future<void> _onChatSignal(ChatSignal signal) async {
    debugPrint('[CHAT-STATE] onChatSignal type=${signal.type.name} from=${signal.fromUserId} to=${signal.toUserId}');
    switch (signal.type) {
      case ChatSignalType.chatMessage:
      case ChatSignalType.chatInit:
        await _routeToConversation(signal);
        break;
      case ChatSignalType.chatReceipt:
        await _routeReceipt(signal);
        break;
      case ChatSignalType.chatDisappearing:
        await _routeToConversation(signal);
        break;
      case ChatSignalType.chatDiag:
        // 诊断上报，无需在接收方处理（服务器已打印）。
        break;
      case ChatSignalType.chatTyping:
        break;
      case ChatSignalType.chatFileOffer:
      case ChatSignalType.chatFileAnswer:
      case ChatSignalType.chatFileIce:
      case ChatSignalType.chatFileDone:
        // 数据通道文件信令：路由到对应会话的控制器。
        await _routeFileSignal(signal);
        break;
    }
  }

  /// 按会话路由入站消息。会话可能尚不存在（首次收到对方消息）→ 用对端 id 建会话。
  Future<void> _routeToConversation(ChatSignal signal) async {
    final remoteUserId = signal.fromUserId;
    var conv = await _db.getConversationByRemote(remoteUserId);
    final conversationId = conv?['id'] as String? ?? 'conv-$remoteUserId';

    final controller = await controllerFor(
      remoteUserId: remoteUserId,
      conversationId: conversationId,
    );

    switch (signal.type) {
      case ChatSignalType.chatMessage:
        await controller.handleIncoming(signal);
        break;
      case ChatSignalType.chatDisappearing:
        await controller.handleDisappearing(signal);
        break;
      default:
        break;
    }
  }

  /// 路由数据通道文件信令（chatFileOffer/Answer/Ice/Done）到对应会话。
  Future<void> _routeFileSignal(ChatSignal signal) async {
    final remoteUserId = signal.fromUserId;
    var conv = await _db.getConversationByRemote(remoteUserId);
    final conversationId = conv?['id'] as String? ?? 'conv-$remoteUserId';

    final controller = await controllerFor(
      remoteUserId: remoteUserId,
      conversationId: conversationId,
    );

    switch (signal.type) {
      case ChatSignalType.chatFileOffer:
        await controller.handleFileOffer(signal);
        break;
      case ChatSignalType.chatFileAnswer:
      case ChatSignalType.chatFileIce:
        await controller.handleFileSignal(signal);
        break;
      default:
        break;
    }
  }

  Future<void> _routeReceipt(ChatSignal signal) async {
    final remoteUserId = signal.fromUserId;
    final conv = await _db.getConversationByRemote(remoteUserId);
    if (conv == null) return;
    final conversationId = conv['id'] as String;
    final controller = await controllerFor(
      remoteUserId: remoteUserId,
      conversationId: conversationId,
    );
    await controller.handleReceipt(signal);
  }

  @override
  void dispose() {
    _chatSub?.cancel();
    _expiryTimer?.cancel();
    _controllers.clear();
    super.dispose();
  }
}

final chatStateProvider =
    StateNotifierProvider<ChatStateNotifier, ChatState>((ref) {
  final db = DatabaseManager.instance;
  final signaling = createSignalingClient();
  return ChatStateNotifier(
    signaling: signaling,
    db: db,
    sessions: ChatSessionManager(db: db, api: ApiClient()),
  );
});
