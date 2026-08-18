import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../shared/widgets/contact_avatar.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../call_state.dart';
import '../ringtone_service.dart';
import '../../../core/network/api_client.dart';
import '../../../core/storage/database.dart';
import '../../../core/webrtc/network_monitor.dart';
import '../../../core/webrtc/webrtc_manager.dart';

class CallScreen extends ConsumerStatefulWidget {
  final String contactId;
  const CallScreen({super.key, required this.contactId});

  @override
  ConsumerState<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends ConsumerState<CallScreen> {
  static String _initial(String name) => name.isNotEmpty ? name[0].toUpperCase() : '?';
  bool _isMuted = false;
  bool _isSpeakerOn = false;
  bool _hasCall = false;
  String? _avatarPath;

  @override
  void initState() {
    super.initState();
    // 通话中保持屏幕常亮，防止息屏导致音频中断（wakelock_plus）。
    WakelockPlus.enable();
    // Don't await the async init — let the UI render the loading state
    // while microphone permission and WebRTC initialize in the background.
    _initCall();
  }

  Future<void> _initCall() async {
    // Small delay to let the UI frame render first.
    await Future.delayed(const Duration(milliseconds: 100));
    final existingCall = ref.read(callStateProvider);
    if (existingCall != null) return;

    // Ensure microphone permission before starting the call.
    var micStatus = await Permission.microphone.status;
    if (!micStatus.isGranted) {
      micStatus = await Permission.microphone.request();
    }
    if (!micStatus.isGranted) {
      debugPrint('[CALL] microphone permission denied ($micStatus)');
      if (mounted) {
        final action = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Microphone Required'),
            content: const Text('MyPhone needs microphone access to make calls. Please grant permission in Settings.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Open Settings')),
            ],
          ),
        );
        if (action == true) {
          await openAppSettings();
        }
        if (mounted) context.go('/dialer');
      }
      return;
    }

    // Resolve display name: local contact → server lookup → fallback to id.
    var displayName = widget.contactId;
    try {
      final contact = await DatabaseManager.instance.getContact(widget.contactId);
      if (contact != null && contact['display_name'] is String && (contact['display_name'] as String).isNotEmpty) {
        displayName = contact['display_name'] as String;
      }
      if (contact != null) {
        _avatarPath = contact['avatar_path'] as String?;
      }
      if (contact == null || (contact['display_name'] is String && (contact['display_name'] as String).isEmpty)) {
        // Not in local contacts (e.g. redial from history) — ask the server.
        final client = ApiClient();
        try {
          final info = await client.lookupUserById(widget.contactId);
          if (info != null) {
            final name = info['display_name'] as String?;
            if (name != null && name.isNotEmpty) {
              displayName = name;
            }
          }
        } finally {
          client.dispose();
        }
      }
    } catch (_) {}

    if (!mounted) return;
    try {
      await ref.read(callStateProvider.notifier).startOutgoingCall(widget.contactId, displayName);
      // Default to earpiece (not speakerphone) for privacy and to reduce echo.
      final activeCall = ref.read(callStateProvider);
      if (activeCall != null) {
        await activeCall.webrtc.setSpeakerOn(false);
      }
    } on CallNotFoundException catch (e) {
      debugPrint('[CALL] number not found: $e');
      if (mounted) {
        // Play a short "number not found" tone, then return to dialer.
        RingtoneService.playNumberNotFound();
        await Future.delayed(const Duration(seconds: 2));
        RingtoneService.stop();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('The number you dialed does not exist. Please dial again.')),
          );
          context.go('/dialer');
        }
      }
    } catch (e) {
      debugPrint('[CALL] startOutgoingCall failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to start call: $e')),
        );
        context.go('/dialer');
      }
    }
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    RingtoneService.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final call = ref.watch(callStateProvider);

    if (call != null) {
      _hasCall = true;
    }

    // Call was active but now ended — navigate away.
    if (call == null && _hasCall) {
      RingtoneService.stop();
      _hasCall = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.go('/dialer');
      });
      return const SizedBox.shrink();
    }

    // Initial loading — call hasn't started yet.
    if (call == null) {
      return const Scaffold(
        backgroundColor: Color(0xFF1A1A2E),
        body: Center(child: CircularProgressIndicator(color: Colors.white)),
      );
    }

    // Play ringback on outgoing calls; stop when connected or ended.
    if (call.status == CallStatus.ringing && !call.isIncoming) {
      RingtoneService.playRingback();
    } else {
      RingtoneService.stop();
    }
    final networkTier = call.networkMonitor.currentTier;
    final e2ee = call.e2eeSnapshot;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        // 通话界面按返回键：最小化到拨号盘（通话继续，由全局通话条返回）。
        if (!didPop) context.go('/dialer');
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF1A1A2E),
        body: SafeArea(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Spacer(flex: 2),
            ContactAvatar(
              avatarPath: _avatarPath,
              initials: _initial(call.contactName),
              radius: 48,
            ),
            const SizedBox(height: 16),
            Text(call.contactName,
                style: const TextStyle(
                    fontSize: 24,
                    color: Colors.white,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(_statusText(call.status, e2ee.isEncrypted),
                style: const TextStyle(fontSize: 16, color: Colors.white70)),
            const SizedBox(height: 8),
            Text(
              e2ee.status,
              style: TextStyle(
                fontSize: 13,
                color: e2ee.isEncrypted ? Colors.greenAccent : Colors.orangeAccent,
              ),
            ),
            if (e2ee.peerFingerprint != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Peer Fingerprint: ${e2ee.peerFingerprint}',
                  style: const TextStyle(fontSize: 11, color: Colors.white60),
                ),
              ),
            if (networkTier != null) ...[
              const SizedBox(height: 8),
              _NetworkQualityBadge(tier: networkTier)
            ],
            const SizedBox(height: 8),
            StreamBuilder<NetworkStats>(
              stream: call.networkMonitor.stats,
              builder: (context, _) =>
                  _CallPathBadge(path: call.networkMonitor.path),
            ),
            if (call.status == CallStatus.connected) ...[
              const SizedBox(height: 8),
              Text(call.formattedDuration,
                  style: const TextStyle(fontSize: 20, color: Colors.white))
            ],
            const Spacer(flex: 2),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 48),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _CircleButton(
                      icon: _isMuted ? Icons.mic_off : Icons.mic,
                      color: _isMuted ? Colors.red : Colors.white24,
                      onTap: () {
                        final activeCall = ref.read(callStateProvider);
                        if (activeCall == null) return;
                        setState(() {
                          _isMuted = !_isMuted;
                          if (_isMuted) {
                            activeCall.webrtc.mute();
                          } else {
                            activeCall.webrtc.unmute();
                          }
                        });
                      }),
                  _CircleButton(
                      icon: Icons.chat_bubble_outline,
                      color: Colors.white24,
                      onTap: () {
                        final activeCall = ref.read(callStateProvider);
                        if (activeCall == null) return;
                        // 切到聊天页：通话界面留在栈底，通话与计时继续。
                        context.push('/chat/${activeCall.contactId}');
                      }),
                  _CircleButton(
                      icon: Icons.call_end,
                      color: Colors.red,
                      size: 72,
                      onTap: () async {
                        RingtoneService.stop();
                        await ref.read(callStateProvider.notifier).hangup();
                        if (mounted) context.go('/dialer');
                      }),
                  _CircleButton(
                      icon: _isSpeakerOn ? Icons.volume_up : Icons.volume_off,
                      color: _isSpeakerOn ? Colors.white24 : Colors.red,
                      onTap: () {
                        final activeCall = ref.read(callStateProvider);
                        if (activeCall == null) return;
                        setState(() => _isSpeakerOn = !_isSpeakerOn);
                        activeCall.webrtc.toggleSpeaker();
                      }),
                ],
              ),
            ),
            const SizedBox(height: 48),
          ],
        ),
      ),
      ),
    );
  }

  String _statusText(CallStatus? status, bool isE2eeReady) => switch (status) {
        CallStatus.ringing => 'Ringing...',
        CallStatus.connecting => 'Connecting...',
        CallStatus.connected => isE2eeReady
            ? 'Connected (E2E Encrypted)'
            : 'Connected (Transport Encrypted)',
        CallStatus.ended => 'Call Ended',
        _ => '',
      };
}

class _CircleButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final double size;
  final VoidCallback onTap;
  const _CircleButton(
      {required this.icon,
      required this.color,
      required this.onTap,
      this.size = 56});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          child: Icon(icon, color: Colors.white, size: size * 0.5)),
    );
  }
}

class _NetworkQualityBadge extends StatelessWidget {
  final NetworkTier tier;
  const _NetworkQualityBadge({required this.tier});

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (tier) {
      NetworkTier.excellent => ('Excellent', Colors.green),
      NetworkTier.good => ('Good', Colors.lightGreen),
      NetworkTier.moderate => ('Fair', Colors.orange),
      NetworkTier.poor => ('Low Bandwidth', Colors.red),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
          color: color.withOpacity(0.2),
          borderRadius: BorderRadius.circular(12)),
      child: Text(label,
          style: TextStyle(
              color: color, fontSize: 12, fontWeight: FontWeight.w600)),
    );
  }
}

/// 显示通话实际走的媒体路径(由 ICE 最终选中的候选对解析)。
class _CallPathBadge extends StatelessWidget {
  final CallPath path;
  const _CallPathBadge({required this.path});

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (path) {
      CallPath.p2p => ('P2P 直连', Colors.green),
      CallPath.relay => ('TURN 中继', Colors.orange),
      CallPath.unknown => ('连接中…', Colors.grey),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
          color: color.withOpacity(0.2),
          borderRadius: BorderRadius.circular(12)),
      child: Text(label,
          style: TextStyle(
              color: color, fontSize: 12, fontWeight: FontWeight.w600)),
    );
  }
}
