import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../features/auth/screens/login_screen.dart';
import '../features/auth/screens/phone_login_screen.dart';
import '../features/calls/screens/call_screen.dart';
import '../features/calls/screens/dialer_screen.dart';
import '../features/calls/screens/incoming_call_screen.dart';
import '../features/calls/screens/keypad_screen.dart';
import '../features/chat/screens/chat_screen.dart';
import '../features/chat/screens/conversations_screen.dart';
import '../features/contacts/screens/contacts_screen.dart';
import '../features/contacts/screens/contact_detail_screen.dart';
import '../features/settings/screens/settings_screen.dart';
import 'auth_guard.dart';

final rootNavigatorKey = GlobalKey<NavigatorState>();

/// 当前路由位置（path 字符串，如 '/dialer'、'/chat/xxx'、'/call/xxx'）。
/// 由 routerProvider 监听 routerDelegate 回写，供全局浮层（通话条）判断
/// "当前是否正在通话界面"。
final currentLocationProvider = StateProvider<String?>((ref) => null);

final routerProvider = Provider<GoRouter>((ref) {
  final router = GoRouter(
    navigatorKey: rootNavigatorKey,
    initialLocation: '/login',
    redirect: (context, state) async {
      final loggedIn = await AuthGuard.isLoggedIn();
      final isAuthRoute = state.matchedLocation == '/login' ||
          state.matchedLocation == '/phone-login';

      if (!loggedIn && !isAuthRoute) return '/login';
      if (loggedIn && isAuthRoute) return '/dialer';
      return null;
    },
    routes: [
      GoRoute(
        path: '/login',
        builder: (context, state) => const LoginScreen(),
      ),
      GoRoute(
        path: '/phone-login',
        builder: (context, state) => PhoneLoginScreen(
          prefillPhone: state.extra as String?,
        ),
      ),
      GoRoute(
        path: '/dialer',
        builder: (context, state) => const DialerScreen(),
      ),
      GoRoute(
        path: '/keypad',
        builder: (context, state) => const KeypadScreen(),
      ),
      GoRoute(
        path: '/incoming-call',
        builder: (context, state) => const IncomingCallScreen(),
      ),
      GoRoute(
        path: '/settings',
        builder: (context, state) => const SettingsScreen(),
      ),
      GoRoute(
        path: '/conversations',
        builder: (context, state) => const ConversationsScreen(),
      ),
      GoRoute(
        path: '/chat/:contactId',
        builder: (context, state) {
          final contactId = state.pathParameters['contactId']!;
          return ChatScreen(contactId: contactId);
        },
      ),
      GoRoute(
        path: '/call/:contactId',
        builder: (context, state) {
          final contactId = state.pathParameters['contactId']!;
          return CallScreen(contactId: contactId);
        },
      ),
      GoRoute(
        path: '/contacts',
        builder: (context, state) => const ContactsScreen(),
        routes: [
          GoRoute(
            path: ':contactId',
            builder: (context, state) {
              final contactId = state.pathParameters['contactId']!;
              return ContactDetailScreen(contactId: contactId);
            },
          ),
        ],
      ),
    ],
  );

  // 导航变化时回写当前路径，供全局浮层（通话条）判断所在页面。
  router.routerDelegate.addListener(() {
    ref.read(currentLocationProvider.notifier).state =
        router.routerDelegate.currentConfiguration.uri.toString();
  });
  return router;
});
