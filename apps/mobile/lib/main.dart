import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:go_router/go_router.dart';
import 'app/router.dart';
import 'app/theme.dart';
import 'core/network/service_bridge.dart';
import 'features/calls/incoming_call_state.dart';
import 'features/calls/widgets/call_active_banner.dart';

Future<void> _reportDebug(String hypothesisId, String message, Map<String, Object?> data) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(Uri.parse('http://192.168.3.113:7777/event'));
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode({
      'sessionId': 'mobile-crash',
      'runId': 'pre-fix',
      'hypothesisId': hypothesisId,
      'location': 'lib/main.dart',
      'msg': '[DEBUG] $message',
      'data': data,
      'ts': DateTime.now().millisecondsSinceEpoch,
    }));
    await request.close();
  } catch (_) {
  } finally {
    client.close(force: true);
  }
}

void main() {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    // v0.4: 加载持久化常驻开关，决定 createSignalingClient 的传输选型。
    if (Platform.isAndroid) {
      try {
        const _storage = FlutterSecureStorage(
          aOptions: AndroidOptions(
            encryptedSharedPreferences: true,
            resetOnError: true,
          ),
        );
        final v = await _storage.read(key: 'settings_resident');
        ResidentService.enabled = v != 'false';
      } catch (_) {}
    }
    if (kDebugMode) {
      // #region debug-point A:flutter-error
      FlutterError.onError = (details) {
        FlutterError.presentError(details);
        unawaited(_reportDebug('A', 'Flutter framework error', {
          'exception': details.exceptionAsString(),
          'library': details.library,
          'context': details.context?.toDescription(),
        }));
      };
      // #endregion
    }
    runApp(const ProviderScope(child: MyPhoneApp()));
  }, (error, stack) {
    if (kDebugMode) {
      // #region debug-point A:zone-error
      unawaited(_reportDebug('A', 'Unhandled zone error', {
        'error': error.toString(),
        'stack': stack.toString(),
      }));
      // #endregion
    }
    debugPrint('FATAL: $error\n$stack');
  });
}

class MyPhoneApp extends ConsumerStatefulWidget {
  const MyPhoneApp({super.key});
  @override
  ConsumerState<MyPhoneApp> createState() => _MyPhoneAppState();
}

class _MyPhoneAppState extends ConsumerState<MyPhoneApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // v0.4 常驻服务桥接：注册冷启动来电注入 + 启动心跳 + 前台上报。
    AppIncomingCallBridge.register((call) {
      ref.read(incomingCallProvider.notifier).setIncoming(call);
      return true;
    });
    ResidentService.startHeartbeat();
    unawaited(_initResidentBridge());
  }

  Future<void> _initResidentBridge() async {
    // P1-H：resume 自愈——服务被 OEM 杀后重拉（ensureStarted 幂等）。
    //   若在冷启动后用户立即回前台，此时服务可能已死但 WS 没恢复在线。
    await ResidentService.ensureStarted();
    // 回前台/冷启动：通知服务 app 已存活，读取挂起来电注入。
    await ResidentService.notifyForegrounded();
    await ResidentService.injectPendingIncoming();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final active = state == AppLifecycleState.resumed;
    unawaited(ResidentService.setAppActive(active));
    if (active) {
      unawaited(_initResidentBridge());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ResidentService.stopHeartbeat();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(routerProvider);

    ref.listen<PendingIncomingCall?>(incomingCallProvider, (prev, next) {
      // Navigate on every *new* incoming call. The `prev == null` fast path
      // covers the common case; the callId comparison also catches the case
      // where the previous pending call was never cleared (e.g. after it was
      // accepted), so repeated calls still surface the incoming screen instead
      // of being swallowed by a stale non-null `prev`.
      if (next != null && (prev == null || prev.callId != next.callId)) {
        final navContext = rootNavigatorKey.currentContext;
        if (navContext != null) {
          GoRouter.of(navContext).push('/incoming-call');
        }
      }
    });

    return MaterialApp.router(
      title: 'MyPhone',
      theme: appTheme,
      darkTheme: darkAppTheme,
      themeMode: ThemeMode.system,
      routerConfig: router,
      debugShowCheckedModeBanner: false,
      // 全局通话条：通话进行中且不在通话界面时悬浮于任意页面上方。
      builder: (context, child) => Stack(
        children: [
          if (child != null) child,
          const CallActiveBanner(),
        ],
      ),
    );
  }
}
