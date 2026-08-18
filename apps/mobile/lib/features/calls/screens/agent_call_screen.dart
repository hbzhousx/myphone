/// AI 语音通话界面（哪吒/智能体）—— v1.50。
///
/// 全屏暗色会话：头像 + 「哪吒 AI 通话」+ 状态；中部实时字幕（用户/Agent
/// 分色）；底部静音 / 结束 / 扬声器。通话内容与聊天页互通（落库走 bot 明文旁路）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../../shared/widgets/contact_avatar.dart';
import '../../../core/storage/database.dart';
import '../agent_call_state.dart';
import '../call_state.dart';

class AgentCallScreen extends ConsumerStatefulWidget {
  final String contactId;
  const AgentCallScreen({super.key, required this.contactId});

  @override
  ConsumerState<AgentCallScreen> createState() => _AgentCallScreenState();
}

class _AgentCallScreenState extends ConsumerState<AgentCallScreen> {
  static String _initial(String name) => name.isNotEmpty ? name[0].toUpperCase() : '?';

  String _displayName = '哪吒';
  String? _avatarPath;
  bool _muted = false;
  bool _speakerOn = false;
  bool _hasSession = false;

  @override
  void initState() {
    super.initState();
    // 通话中保持屏幕常亮。
    WakelockPlus.enable();
    _initCall();
  }

  Future<void> _initCall() async {
    // 与真实通话互斥：已有真实通话时提示并返回聊天页。
    if (ref.read(callStateProvider) != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('正在真实通话中，无法发起 AI 通话')),
        );
        context.go('/chat/${widget.contactId}');
      });
      return;
    }

    // 解析显示名（哪吒）+ 头像。
    try {
      final contact = await DatabaseManager.instance.getContact(widget.contactId);
      if (contact != null) {
        if (contact['display_name'] is String && (contact['display_name'] as String).isNotEmpty) {
          _displayName = contact['display_name'] as String;
        }
        _avatarPath = contact['avatar_path'] as String?;
      }
    } catch (_) {}

    if (!mounted) return;
    // 发起 AI 会话。
    await ref.read(agentCallStateProvider.notifier).start(
          contactId: widget.contactId,
          contactName: _displayName,
        );
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    super.dispose();
  }

  void _hangupAndLeave() async {
    await ref.read(agentCallStateProvider.notifier).hangup();
    if (mounted) context.go('/chat/${widget.contactId}');
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(agentCallStateProvider);

    // 会话曾经存在但已结束（挂断/媒体端点 ended）→ 离开。
    if (session == null && _hasSession) {
      _hasSession = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.go('/chat/${widget.contactId}');
      });
      return const Scaffold(
        backgroundColor: Color(0xFF1A1A2E),
        body: SizedBox.shrink(),
      );
    }

    // 初始加载：会话未建立。
    if (session == null) {
      return const Scaffold(
        backgroundColor: Color(0xFF1A1A2E),
        body: Center(child: CircularProgressIndicator(color: Colors.white)),
      );
    }
    _hasSession = true;

    final statusText = switch (session.status) {
      AgentCallStatus.connecting => session.statusText ?? '连接中…',
      AgentCallStatus.connected => session.statusText ?? '已连接',
      AgentCallStatus.ended => '已结束',
      AgentCallStatus.idle => '',
    };

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        // 返回键 = 挂断 + 回聊天页。
        if (!didPop) _hangupAndLeave();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF1A1A2E),
        body: SafeArea(
          child: Column(
            children: [
              const Spacer(flex: 1),
              ContactAvatar(
                avatarPath: _avatarPath,
                initials: _initial(_displayName),
                radius: 48,
              ),
              const SizedBox(height: 16),
              Text('$_displayName AI 通话',
                  style: const TextStyle(
                      fontSize: 24, color: Colors.white, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: session.status == AgentCallStatus.connected
                          ? Colors.greenAccent
                          : Colors.orangeAccent,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(statusText,
                      style: const TextStyle(fontSize: 15, color: Colors.white70)),
                ],
              ),
              const Spacer(flex: 1),
              // 实时字幕。
              Expanded(
                child: session.transcripts.isEmpty
                    ? const Center(
                        child: Text('与智能体对话中，字幕将显示在这里',
                            style: TextStyle(color: Colors.white38, fontSize: 14)),
                      )
                    : ListView.builder(
                        reverse: true,
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                        itemCount: session.transcripts.length,
                        itemBuilder: (context, index) {
                          final t = session.transcripts[
                              session.transcripts.length - 1 - index];
                          return _TranscriptRow(transcript: t);
                        },
                      ),
              ),
              const Spacer(flex: 1),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _AgentCircleButton(
                      icon: _muted ? Icons.mic_off : Icons.mic,
                      color: _muted ? Colors.red : Colors.white24,
                      onTap: () {
                        setState(() => _muted = !_muted);
                        ref.read(agentCallStateProvider.notifier).toggleMute();
                      },
                    ),
                    _AgentCircleButton(
                      icon: Icons.call_end,
                      color: Colors.red,
                      size: 72,
                      onTap: _hangupAndLeave,
                    ),
                    _AgentCircleButton(
                      icon: _speakerOn ? Icons.volume_up : Icons.volume_off,
                      color: _speakerOn ? Colors.white24 : Colors.red,
                      onTap: () async {
                        setState(() => _speakerOn = !_speakerOn);
                        await ref
                            .read(agentCallStateProvider.notifier)
                            .toggleSpeaker();
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 字幕行：用户说话 / Agent 说话分色；临时（未定稿）字幕更淡。
class _TranscriptRow extends StatelessWidget {
  final AgentTranscript transcript;
  const _TranscriptRow({required this.transcript});

  @override
  Widget build(BuildContext context) {
    final isUser = transcript.who == 'user';
    final color = isUser ? Colors.lightBlueAccent : Colors.greenAccent;
    final opacity = transcript.isFinal ? 1.0 : 0.55;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment:
            isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          if (!isUser)
            Container(
              margin: const EdgeInsets.only(right: 8),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.green.withOpacity(0.25),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Text('AI',
                  style: TextStyle(color: Colors.greenAccent, fontSize: 11)),
            ),
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: isUser ? Colors.blue.withOpacity(0.18) : Colors.white10,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                transcript.text,
                style: TextStyle(
                  color: color.withOpacity(opacity),
                  fontSize: 15,
                  height: 1.3,
                ),
              ),
            ),
          ),
          if (isUser)
            Container(
              margin: const EdgeInsets.only(left: 8),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.blue.withOpacity(0.25),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Text('我',
                  style: TextStyle(color: Colors.lightBlueAccent, fontSize: 11)),
            ),
        ],
      ),
    );
  }
}

class _AgentCircleButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final double size;
  final VoidCallback onTap;
  const _AgentCircleButton(
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
