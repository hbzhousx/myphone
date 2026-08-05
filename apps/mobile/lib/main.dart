import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'app/router.dart';
import 'app/theme.dart';
import 'features/calls/incoming_call_state.dart';

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

class MyPhoneApp extends ConsumerWidget {
  const MyPhoneApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
    );
  }
}
