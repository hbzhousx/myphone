/// 显示当前网络决定的 ICE 策略:走 P2P 直连还是 TURN 中继。
///
/// 复用 v0.3 的 determineIcePolicy()(UDP 探测):
///   p2p  → 可直连(绿色)
///   relay → UDP 受限,走 TURN 中继(橙色)
library;

import 'package:flutter/material.dart';

import '../../../core/webrtc/ice_policy.dart';
import '../../../core/webrtc/webrtc_manager.dart';

class IcePolicyBadge extends StatelessWidget {
  const IcePolicyBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<IcePolicy>(
      future: determineIcePolicy(
        stunUrl: WebrtcManager.stunUrl,
        turnUrl: WebrtcManager.turnUrl,
      ),
      builder: (context, snapshot) {
        final policy = snapshot.data ?? IcePolicy.auto;
        final (label, color) = switch (policy) {
          IcePolicy.p2p => ('走 P2P 直连', Colors.green),
          IcePolicy.relay => ('走 TURN 中继', Colors.orange),
          IcePolicy.auto => ('检测中…', Colors.grey),
        };
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(
            children: [
              Icon(Icons.network_check, size: 14, color: color),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  color: color,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
