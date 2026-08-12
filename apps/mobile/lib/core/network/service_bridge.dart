/// v0.4 常驻服务桥接层。
///
/// [ServiceBridgeSignalingClient]：Android 常驻开启时替代 DirectWS —— 不自己
/// 建 WebSocket，发送经 MethodChannel 交给 CallService，接收经 EventChannel
/// 拿到服务推来的信令。服务负责独占 WS、心跳、重连与"保持登录"。
///
/// [ResidentService]：常驻服务的生命周期入口（登录/进入拨号盘时拉起，幂等）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../app/auth_guard.dart';
import '../../features/calls/incoming_call_state.dart';
import 'chat_signal.dart';
import 'server_config.dart';
import 'signaling_client.dart';

/// 按平台 + 常驻开关选择信令传输实现。
/// 常驻开关在 [ResidentService.enabled]，由设置页持久化。
///
/// ★进程内 WS 必须单例：callStateProvider 与 chatStateProvider 都调用本函数。
/// 若不缓存，DirectWS 模式会建出两个独立 WebSocket → 服务器 register 时新连接
/// 覆盖旧连接并互踢 → 客户端反复重连 → 呼叫信令目标"不在线"导致呼叫不通。
SignalingClient createSignalingClient() {
  _signalingSingleton ??= (Platform.isAndroid && ResidentService.enabled)
      ? ServiceBridgeSignalingClient()
      : DirectWSSignalingClient();
  return _signalingSingleton!;
}

SignalingClient? _signalingSingleton;

/// 常驻服务生命周期（登录成功 / 进入拨号盘时调用，幂等）。
class ResidentService {
  static const MethodChannel _channel = MethodChannel('myphone/service');

  /// 常驻开关（Android 运行时）：由设置页持久化并在此同步。
  static bool enabled = true;

  /// 应用常驻开关：关闭时停止服务；打开时拉起服务。
  static Future<void> applyEnabled(bool value) async {
    enabled = value;
    if (!Platform.isAndroid) return;
    if (value) {
      await ensureStarted();
    } else {
      await logout();
    }
  }

  /// 拉起前台服务并注入 token + 服务器配置。若未登录或已启动则无副作用。
  static Future<void> ensureStarted() async {
    if (!Platform.isAndroid || !enabled) return;
    final token = await AuthGuard.getToken();
    if (token == null || token.isEmpty) return;
    await _channel.invokeMethod('startForegroundService', {
      'token': token,
      'host': ServerConfig.host,
      'port': ServerConfig.port,
      'useTls': ServerConfig.useTls,
    });
  }

  /// 登出：通知服务断 WS（离线）并停止常驻。
  static Future<void> logout() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod('logout');
  }

  /// 接听/拒绝来电后显式停原生响铃（兜底原生响铃未自动停的场景）。
  static Future<void> stopNativeRing() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod('stopNativeRing');
  }

  /// 启动 Flutter 心跳（10s），服务侧据此判断 app 是否仍存活。
  static Timer? _heartbeat;
  static void startHeartbeat() {
    if (!Platform.isAndroid || !enabled) return;
    _heartbeat ??= Timer.periodic(const Duration(seconds: 10), (_) async {
      try {
        await _channel.invokeMethod('heartbeat');
      } catch (_) {}
    });
  }
  static void stopHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = null;
  }

  /// app 前台状态上报（服务据此决定来电呈现方式）。
  static Future<void> setAppActive(bool active) async {
    if (!Platform.isAndroid || !enabled) return;
    await _channel.invokeMethod('setAppActive', {'active': active});
  }

  /// Flutter resumed：通知服务 app 已回前台，重发挂起来电。
  static Future<void> notifyForegrounded() async {
    if (!Platform.isAndroid || !enabled) return;
    await _channel.invokeMethod('appForegrounded');
  }

  /// 冷启动/回前台时读取原生缓存的来电 extras 并注入 incomingCallProvider。
  /// 返回 true 表示有挂起来电被注入。
  static Future<bool> injectPendingIncoming() async {
    if (!Platform.isAndroid) return false;
    try {
      final extras = await _channel.invokeMethod('getIncomingExtras');
      if (extras is! Map) return false;
      final offerJson = extras['offerJson'] as String?;
      if (offerJson == null || offerJson.isEmpty) return false;
      final msg = jsonDecode(offerJson) as Map<String, dynamic>;
      final callId = msg['call_id'] as String?;
      final from = msg['from_user_id'] as String?;
      if (callId == null || from == null) return false;
      final payload = (msg['payload'] as Map<String, dynamic>?) ?? const {};
      final sdp = payload['sdp'] as String? ?? '';
      final e2ee = payload['e2ee'];
      if (e2ee is! Map<String, dynamic>) return false;

      // 通知服务已接管该来电（停原生响铃）。
      await _channel.invokeMethod('clearIncomingExtras');

      // 注入现有来电状态，main.dart 的 ref.listen 会自动导航到 incoming-call。
      final controller =
          AppIncomingCallBridge.setIncoming(PendingIncomingCall(
        callId: callId,
        contactId: from,
        contactName: from, // 名字可由联系人表进一步解析，此处先用 id
        sdpOffer: sdp,
        e2eeOffer: e2ee,
      ));
      debugPrint('[SERVICE-BRIDGE] injected pending incoming call=$callId from=$from');
      return controller;
    } catch (e) {
      debugPrint('[SERVICE-BRIDGE] inject failed: $e');
      return false;
    }
  }
}

/// 让 service_bridge 不直接依赖 Riverpod 的 provider 实例（避免循环 import），
/// 由 main.dart 注册回调。
class AppIncomingCallBridge {
  static bool Function(PendingIncomingCall call)? _setter;
  static void register(bool Function(PendingIncomingCall call) setter) {
    _setter = setter;
  }
  static bool setIncoming(PendingIncomingCall call) {
    final s = _setter;
    if (s == null) return false;
    return s(call);
  }
}

/// 桥接信令客户端（服务独占 WS）。
class ServiceBridgeSignalingClient extends SignalingClient {
  static const MethodChannel _channel = MethodChannel('myphone/service');
  static const EventChannel _events = EventChannel('myphone/service_events');

  final _signalController = StreamController<CallSignal>.broadcast();
  final _chatController = StreamController<ChatSignal>.broadcast();
  StreamSubscription? _eventSub;

  @override
  Stream<CallSignal> get signals => _signalController.stream;

  @override
  Stream<ChatSignal> get chatSignals => _chatController.stream;

  @override
  set onDisconnected(VoidCallback? cb) {
    // 桥接模式不触发 onDisconnected：服务自愈重连，由服务端保证在线。
  }

  @override
  Future<void> connect() async {
    _eventSub ??= _events.receiveBroadcastStream().listen(
      (data) {
        if (data is! String) return;
        try {
          final json = jsonDecode(data) as Map<String, dynamic>;
          debugPrint('[SERVICE-BRIDGE] recv ${json['type']} callId=${json['call_id']} from=${json['from_user_id']}');
          final typ = json['type'] as String?;
          if (typ != null && ChatSignal.typeNames.contains(typ)) {
            _chatController.add(ChatSignal.fromJson(json));
            return;
          }
          _signalController.add(CallSignal.fromJson(json));
        } catch (_) {
          debugPrint('[SERVICE-BRIDGE] bad signal: $data');
        }
      },
      onError: (Object _) {
        // 服务自愈重连，Flutter 侧不把断连上报给 CallStateNotifier。
      },
    );
  }

  @override
  void sendSignal(CallSignal signal) {
    final data = jsonEncode(signal.toJson());
    debugPrint('[SERVICE-BRIDGE] send type=${signal.type.name} to=${signal.toUserId} callId=${signal.callId}');
    _channel.invokeMethod('sendSignal', {'signal': data});
  }

  @override
  void sendChatSignal(ChatSignal signal) {
    final data = jsonEncode(signal.toJson());
    debugPrint('[SERVICE-BRIDGE] send chat type=${signal.type.name} to=${signal.toUserId} msgId=${signal.messageId}');
    _channel.invokeMethod('sendSignal', {'signal': data});
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    _eventSub = null;
    _signalController.close();
    _chatController.close();
  }
}
