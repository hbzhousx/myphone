import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/network/service_bridge.dart';
import '../call_state.dart';
import '../incoming_call_state.dart';
import '../ringtone_service.dart';

class IncomingCallScreen extends ConsumerStatefulWidget {
  const IncomingCallScreen({super.key});
  @override
  ConsumerState<IncomingCallScreen> createState() => _IncomingCallScreenState();
}

class _IncomingCallScreenState extends ConsumerState<IncomingCallScreen> {
  static String _initial(String name) => name.isNotEmpty ? name[0].toUpperCase() : '?';
  @override
  void dispose() {
    RingtoneService.stop();
    super.dispose();
  }

  Future<void> _decline(WidgetRef ref, PendingIncomingCall incoming) async {
    RingtoneService.stop();
    // 停原生响铃（兜底：冷启动/后台拉起时原生响铃可能未停）。
    unawaited(ResidentService.stopNativeRing());
    final notifier = ref.read(callStateProvider.notifier);
    await notifier.declineIncomingCall(incoming);
    ref.read(incomingCallProvider.notifier).clear();
    if (mounted) context.go('/dialer');
  }

  Future<void> _accept(WidgetRef ref, PendingIncomingCall incoming) async {
    RingtoneService.stop();
    // 停原生响铃（兜底：冷启动/后台拉起时原生响铃可能未停）。
    unawaited(ResidentService.stopNativeRing());
    final contactId = incoming.contactId;
    try {
      await ref.read(callStateProvider.notifier).acceptIncomingCall(
        callId: incoming.callId,
        contactId: incoming.contactId,
        contactName: incoming.contactName,
        sdpOffer: incoming.sdpOffer,
        e2eeOffer: incoming.e2eeOffer,
      );
      // Default to earpiece when answering.
      final activeCall = ref.read(callStateProvider);
      if (activeCall != null) {
        await activeCall.webrtc.setSpeakerOn(false);
      }
    } catch (e) {
      debugPrint('[CALL] accept failed: $e');
      // Accept failed — clean up so the user can retry or go back.
      ref.read(incomingCallProvider.notifier).clear();
      if (mounted) context.go('/dialer');
      return;
    }
    // Clear the pending incoming call so a later call re-triggers the
    // navigation listener in main.dart (which only fires on a *new* call).
    ref.read(incomingCallProvider.notifier).clear();
    // Navigate away.
    if (mounted) context.go('/call/$contactId');
  }

  @override
  Widget build(BuildContext context) {
    final incoming = ref.watch(incomingCallProvider);
    if (incoming == null) {
      // If a call was just accepted, `_accept` navigates to the active call
      // screen itself — don't race it back to the dialer.
      final hasActiveCall = ref.read(callStateProvider) != null;
      if (!hasActiveCall) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) context.go('/dialer');
        });
      }
      return const SizedBox.shrink();
    }

    // Start ringtone playback.
    RingtoneService.playRingtone();

    return Scaffold(
      backgroundColor: const Color(0xFF1A1A2E),
      body: SafeArea(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Spacer(flex: 2),
            CircleAvatar(
              radius: 48,
              backgroundColor: Colors.white24,
              child: Text(
                _initial(incoming.contactName),
                style: const TextStyle(fontSize: 36, color: Colors.white),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              incoming.contactName,
              style: const TextStyle(
                fontSize: 24,
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Incoming Call',
              style: TextStyle(fontSize: 16, color: Colors.white70),
            ),
            const Spacer(flex: 2),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 48),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _CircleButton(
                    icon: Icons.call_end,
                    color: Colors.red,
                    size: 72,
                    onTap: () => _decline(ref, incoming),
                  ),
                  _CircleButton(
                    icon: Icons.call,
                    color: Colors.green,
                    size: 72,
                    onTap: () => _accept(ref, incoming),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 48),
          ],
        ),
      ),
    );
  }
}

class _CircleButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final double size;
  final VoidCallback onTap;
  const _CircleButton({
    required this.icon,
    required this.color,
    required this.onTap,
    this.size = 56,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: color.withOpacity(0.8),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: Colors.white, size: size * 0.5),
      ),
    );
  }
}
