/// 自适应 ICE 策略:根据当前网络 UDP 出站是否可达,决定走 P2P(直连)还是 relay(TURN)。
///
/// 背景:v0.2 为修复跨网络通话,强制 `iceTransportPolicy: relay`。但强制 relay 会
/// 牺牲同网/P2P 场景的低延迟直连。v0.3 改为**预探测 + 动态决策**:
///   - 预探测:向 STUN 服务器发一个 UDP binding,若收到响应 → UDP 出站可达 → P2P(all);
///     超时 → UDP 受限(如国内运营商限制 App UDP)→ relay。
///   - 探测失败(无网络等)→ 默认 relay(保守,保证可用)。
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';

/// ICE 传输策略。
enum IcePolicy {
  /// 只走 TURN relay(强制中继)。
  relay,

  /// 允许 P2P(host/srflx)直连,不通时 ICE 自动 fallback 到 relay。
  p2p,

  /// 由 [determineIcePolicy] 探测后自动决定(默认)。
  auto,
}

/// STUN magic cookie(探测用)。
const _magicCookie = 0x2112A442;

List<int> _buildStunBinding() {
  final bytes = <int>[
    0x00, 0x01, // 0x0001 Binding
    0x00, 0x00, // 长度 0(无属性)
    (_magicCookie >> 24) & 0xff, (_magicCookie >> 16) & 0xff,
    (_magicCookie >> 8) & 0xff, _magicCookie & 0xff,
  ];
  final rng = Random();
  for (var i = 0; i < 12; i++) {
    bytes.add(rng.nextInt(256));
  }
  return bytes;
}

/// 探测当前网络 UDP 出站是否可达:向 [host]:[port] 发 STUN binding,
/// 在 [timeout] 内收到响应返回 true;否则 false。
Future<bool> _probeUdp(String host, int port,
    {Duration timeout = const Duration(seconds: 3)}) async {
  final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  try {
    socket.broadcastEnabled = false;
    final completer = Completer<bool>();
    var done = false;

    socket.listen((event) {
      if (done) return;
      if (event == RawSocketEvent.read) {
        socket.receive();
        done = true;
        completer.complete(true);
      } else if (event == RawSocketEvent.closed) {
        done = true;
        completer.complete(false);
      }
    });

    socket.send(_buildStunBinding(), InternetAddress(host), port);

    return await completer.future.timeout(timeout, onTimeout: () {
      done = true;
      return false;
    });
  } finally {
    socket.close();
  }
}

/// 从 `stun:host:port` 或 `turn:host:port` URL 解析 host/port。
({String host, int port})? _parseServerUrl(String? url) {
  if (url == null || url.isEmpty) return null;
  final m = RegExp(r'^(stun|turn|turns):([^:]+)(?::(\d+))?').firstMatch(url);
  if (m == null) return null;
  final host = m.group(2)!;
  final port = int.tryParse(m.group(3) ?? '') ?? 3478;
  return (host: host, port: port);
}

/// 根据当前网络环境决定 ICE 策略:UDP 可达 → P2P;受限/失败 → relay。
Future<IcePolicy> determineIcePolicy({
  String? stunUrl,
  String? turnUrl,
  Duration timeout = const Duration(seconds: 3),
}) async {
  // 优先用 STUN 探测;若无 STUN,退回用 TURN 的 host(3478/udp 也走 UDP)。
  final target = _parseServerUrl(stunUrl) ?? _parseServerUrl(turnUrl);
  if (target == null) {
    if (kDebugMode) debugPrint('[ICEPOLICY] no server url, default relay');
    return IcePolicy.relay;
  }

  try {
    final reachable = await _probeUdp(target.host, target.port, timeout: timeout);
    if (kDebugMode) {
      debugPrint('[ICEPOLICY] UDP ${target.host}:${target.port} reachable=$reachable');
    }
    return reachable ? IcePolicy.p2p : IcePolicy.relay;
  } catch (e) {
    if (kDebugMode) debugPrint('[ICEPOLICY] probe error: $e, default relay');
    return IcePolicy.relay;
  }
}

/// 把 [IcePolicy] 映射为 createPeerConnection 的 iceTransportPolicy 值。
String iceTransportPolicyValue(IcePolicy policy) {
  switch (policy) {
    case IcePolicy.relay:
      return 'relay';
    case IcePolicy.p2p:
    case IcePolicy.auto:
      return 'all';
  }
}
