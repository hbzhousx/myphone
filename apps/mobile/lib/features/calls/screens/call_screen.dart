import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../call_state.dart';
import '../../../core/webrtc/webrtc_manager.dart';

class CallScreen extends ConsumerStatefulWidget {
  final String contactId;
  const CallScreen({super.key, required this.contactId});

  @override
  ConsumerState<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends ConsumerState<CallScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(callStateProvider.notifier).startOutgoingCall(widget.contactId, widget.contactId);
    });
  }

  @override
  Widget build(BuildContext context) {
    final call = ref.watch(callStateProvider);
    final networkTier = call?.networkMonitor.currentTier;

    return Scaffold(
      backgroundColor: const Color(0xFF1A1A2E),
      body: SafeArea(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Spacer(flex: 2),
            CircleAvatar(radius: 48, backgroundColor: Colors.white24, child: Text(widget.contactId[0].toUpperCase(), style: const TextStyle(fontSize: 36, color: Colors.white))),
            const SizedBox(height: 16),
            Text(widget.contactId, style: const TextStyle(fontSize: 24, color: Colors.white, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(_statusText(call?.status), style: const TextStyle(fontSize: 16, color: Colors.white70)),
            if (networkTier != null) ...[const SizedBox(height: 8), _NetworkQualityBadge(tier: networkTier)],
            if (call?.status == CallStatus.connected) ...[const SizedBox(height: 8), Text(call!.formattedDuration, style: const TextStyle(fontSize: 20, color: Colors.white))],
            const Spacer(flex: 2),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 48),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _CircleButton(icon: Icons.mic_off, color: Colors.white24, onTap: () {}),
                  _CircleButton(icon: Icons.call_end, color: Colors.red, size: 72, onTap: () {
                    ref.read(callStateProvider.notifier).hangup();
                    context.go('/dialer');
                  }),
                  _CircleButton(icon: Icons.volume_up, color: Colors.white24, onTap: () {}),
                ],
              ),
            ),
            const SizedBox(height: 48),
          ],
        ),
      ),
    );
  }

  String _statusText(CallStatus? status) => switch (status) {
    CallStatus.ringing => 'Ringing...',
    CallStatus.connecting => 'Connecting...',
    CallStatus.connected => 'Connected (E2E Encrypted)',
    CallStatus.ended => 'Call Ended',
    _ => '',
  };
}

class _CircleButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final double size;
  final VoidCallback onTap;
  const _CircleButton({required this.icon, required this.color, required this.onTap, this.size = 56});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(width: size, height: size, decoration: BoxDecoration(color: color, shape: BoxShape.circle), child: Icon(icon, color: Colors.white, size: size * 0.5)),
    );
  }
}

class _NetworkQualityBadge extends StatelessWidget {
  final NetworkTier tier;
  const _NetworkQualityBadge({required this.tier});

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (tier) {
      NetworkTier.good => ('Excellent', Colors.green),
      NetworkTier.moderate => ('Good', Colors.orange),
      NetworkTier.poor => ('Low Bandwidth', Colors.red),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(color: color.withOpacity(0.2), borderRadius: BorderRadius.circular(12)),
      child: Text(label, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600)),
    );
  }
}
