/// 全局通话条：通话进行中（且不在通话界面时）悬浮在任意页面上方。
/// 展示联系人 + 状态/计时，点击返回通话界面（Signal/Telegram 式折叠通话）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../app/router.dart';
import '../../../shared/widgets/contact_avatar.dart';
import '../call_state.dart';

class CallActiveBanner extends ConsumerWidget {
  const CallActiveBanner({super.key});

  String _statusText(ActiveCall call) {
    switch (call.status) {
      case CallStatus.ringing:
        return '正在呼叫…';
      case CallStatus.connecting:
        return '连接中…';
      case CallStatus.connected:
        return call.formattedDuration;
      default:
        return '通话中';
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final call = ref.watch(callStateProvider);
    if (call == null) return const SizedBox.shrink();

    // 已在通话界面时不显示（避免重复）。
    final location = ref.watch(currentLocationProvider);
    if (location != null && location.startsWith('/call/')) {
      return const SizedBox.shrink();
    }

    final name = call.contactName.trim();
    final initials = name.isEmpty ? '?' : name[0].toUpperCase();

    return Align(
      alignment: Alignment.topCenter,
      child: SafeArea(
        bottom: false,
        child: Material(
          color: const Color(0xFF1A1A2E),
          elevation: 6,
          child: InkWell(
            onTap: () =>
                ref.read(routerProvider).go('/call/${call.contactId}'),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              constraints: const BoxConstraints(maxWidth: 480),
              child: Row(
                children: [
                  ContactAvatar(avatarPath: null, initials: initials, radius: 16),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          call.contactName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          _statusText(call),
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.call,
                      color: Colors.greenAccent, size: 20),
                  const SizedBox(width: 8),
                  const Text(
                    '返回通话',
                    style: TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
