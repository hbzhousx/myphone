/// Monitors network quality (RTT, packet loss, jitter) during calls
/// and adapts the Opus encoder configuration in real-time.
library;

import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

import 'webrtc_manager.dart';

/// 通话实际走的媒体路径(由 ICE 最终选中的候选对决定)。
enum CallPath { p2p, relay, unknown }

class NetworkStats {
  final double rttMs;
  final double packetLossPercent;
  final double jitterMs;
  final DateTime timestamp;

  const NetworkStats({
    required this.rttMs,
    required this.packetLossPercent,
    required this.jitterMs,
    required this.timestamp,
  });

  NetworkTier get tier {
    if (rttMs < 50 && packetLossPercent < 0.5) return NetworkTier.excellent;
    if (rttMs < 100 && packetLossPercent < 2) return NetworkTier.good;
    if (rttMs < 500 && packetLossPercent < 10) return NetworkTier.moderate;
    return NetworkTier.poor;
  }
}

class NetworkMonitor {
  final WebrtcManager _webrtcManager;
  Timer? _monitorTimer;
  NetworkTier _currentTier = NetworkTier.good;
  CallPath _path = CallPath.unknown;

  /// 上次采样时各方向的累计丢包/收包数，用于算区间丢包率。
  int _lastInboundLost = 0;
  int _lastInboundPackets = 0;
  int _lastRemoteLost = 0;
  int _lastRemotePackets = 0;
  int _lastOutboundLost = 0;
  int _lastOutboundPackets = 0;

  final _statsController = StreamController<NetworkStats>.broadcast();
  Stream<NetworkStats> get stats => _statsController.stream;
  NetworkTier get currentTier => _currentTier;

  /// 通话实际走的媒体路径(由 ICE 选中的候选对解析)。
  CallPath get path => _path;

  NetworkMonitor(this._webrtcManager);

  void start() {
    _monitorTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _sampleStats();
    });
  }

  void stop() {
    _monitorTimer?.cancel();
    _monitorTimer = null;
  }

  Future<void> _sampleStats() async {
    final pc = _webrtcManager.peerConnection;
    if (pc == null) return;

    try {
      final stats = await pc.getStats(null);

      // 三个方向的音频统计：
      // - inbound-rtp：本地收到的音频（远端上行质量 → 远端网络差会导致"听不清对方"）
      // - remote-inbound-rtp：远端反馈的"它收到我们的流"（我们上行质量）
      // - outbound-rtp：本地发送（配合 remote-inbound 判断我们上行是否丢包）
      double jitterSum = 0;
      int inboundLost = 0, inboundPackets = 0;
      int remoteLost = 0, remotePackets = 0;
      int outboundLost = 0, outboundPackets = 0;

      for (final report in stats) {
        if (report.values['kind'] != 'audio') continue;
        switch (report.type) {
          case 'inbound-rtp':
            inboundLost += (report.values['packetsLost'] as num? ?? 0).toInt();
            inboundPackets += (report.values['packetsReceived'] as num? ?? 0).toInt();
            jitterSum += (report.values['jitter'] as num? ?? 0).toDouble() * 1000;
            break;
          case 'remote-inbound-rtp':
            remoteLost += (report.values['packetsLost'] as num? ?? 0).toInt();
            remotePackets += (report.values['packetsReceived'] as num? ?? 0).toInt();
            break;
          case 'outbound-rtp':
            outboundLost += (report.values['packetsLost'] as num? ?? 0).toInt();
            outboundPackets += (report.values['packetsSent'] as num? ?? 0).toInt();
            break;
        }
      }

      // 区间丢包率（本采样 - 上采样），避免用累计值误判。
      double lossPct = 0;
      double rttMs = 0;
      double jitterMs = 0;
      int rttCount = 0;

      // 我们上行丢包（remote-inbound 反馈 + outbound 兜底）
      int upLost = remoteLost - _lastRemoteLost;
      int upTotal = (remotePackets - _lastRemotePackets) + upLost;
      if (upTotal > 0 && upLost >= 0) {
        lossPct = (upLost / upTotal) * 100;
      } else if (outboundPackets > 0) {
        // 无 remote-inbound 时，用本地发送自估（弱网会体现在 outbound packetsLost）
        int oLost = outboundLost - _lastOutboundLost;
        int oTotal = (outboundPackets - _lastOutboundPackets) + oLost;
        if (oTotal > 0 && oLost >= 0) lossPct = (oLost / oTotal) * 100;
      }

      // 本地接收丢包（远端网络差，会让我们"听不见对方"）
      int downLost = inboundLost - _lastInboundLost;
      int downTotal = (inboundPackets - _lastInboundPackets) + downLost;
      if (downTotal > 0 && downLost >= 0) {
        final downPct = (downLost / downTotal) * 100;
        if (downPct > lossPct) lossPct = downPct;
      }

      // RTT：优先用 remote-inbound（反映端到端），fallback inbound。
      for (final report in stats) {
        if (report.values['kind'] != 'audio') continue;
        final r = (report.values['roundTripTime'] as num? ?? 0).toDouble();
        if (r > 0) {
          rttMs += r * 1000;
          rttCount++;
        }
      }
      if (rttCount > 0) rttMs /= rttCount;

      if (inboundPackets > 0) {
        final jCount = stats
            .where((s) => s.type == 'inbound-rtp' && s.values['kind'] == 'audio')
            .length;
        jitterMs = jCount > 0 ? jitterSum / jCount : 0;
      }

      _lastInboundLost = inboundLost;
      _lastInboundPackets = inboundPackets;
      _lastRemoteLost = remoteLost;
      _lastRemotePackets = remotePackets;
      _lastOutboundLost = outboundLost;
      _lastOutboundPackets = outboundPackets;

      _resolvePath(stats);

      if (inboundPackets > 0 || outboundPackets > 0) {
        final networkStats = NetworkStats(
          rttMs: rttMs,
          packetLossPercent: lossPct,
          jitterMs: jitterMs,
          timestamp: DateTime.now(),
        );

        _statsController.add(networkStats);

        final newTier = networkStats.tier;
        if (newTier != _currentTier) {
          _currentTier = newTier;
          _webrtcManager.adaptBitrate(newTier);
        }
      }
    } catch (_) {}
  }

  /// 解析 ICE 最终选中的候选对,得出实际媒体路径(relay 中继 或 p2p 直连)。
  ///
  /// 权威方式:从 transport 报告的 selectedCandidatePairId 拿到 ICE 确认选中的
  /// 候选对 id,再查该 candidate-pair 的 localCandidateId → local-candidate 的
  /// candidateType。候选类型 relay → 中继;host/srflx/prflx → 直连。
  void _resolvePath(List<rtc.StatsReport> stats) {
    // local-candidate 的 id 在 StatsReport 顶层(report.id),candidateType 在 values。
    final localTypes = <String, String>{};
    // candidate-pair 的 id → localCandidateId
    final pairLocalIds = <String, String>{};
    // transport 报告声明的 selectedCandidatePairId(可能多个,取第一个)
    String? selectedPairId;

    for (final report in stats) {
      switch (report.type) {
        case 'local-candidate':
          final type = report.values['candidateType'] as String?;
          if (type != null) localTypes[report.id] = type;
        case 'candidate-pair':
          final localId = report.values['localCandidateId'] as String?;
          if (localId != null) pairLocalIds[report.id] = localId;
        case 'transport':
          final sid = report.values['selectedCandidatePairId'] as String?;
          if (sid != null && selectedPairId == null) selectedPairId = sid;
      }
    }

    CallPath resolved = _path;
    // 用 transport 确认的选中候选对
    if (selectedPairId != null) {
      final localId = pairLocalIds[selectedPairId];
      final type = localId != null ? localTypes[localId] : null;
      if (type == 'relay') {
        resolved = CallPath.relay;
      } else if (type == 'host' || type == 'srflx' || type == 'prflx') {
        resolved = CallPath.p2p;
      }
    }
    // 兜底:没有 selectedCandidatePairId 时,用最后一个 succeeded 的候选对。
    if (resolved == _path) {
      for (final report in stats) {
        if (report.type != 'candidate-pair') continue;
        final state = report.values['state'] as String?;
        if (state != 'succeeded') continue;
        final localId = report.values['localCandidateId'] as String?;
        final type = localId != null ? localTypes[localId] : null;
        if (type == 'relay') {
          resolved = CallPath.relay;
        } else if (type == 'host' || type == 'srflx' || type == 'prflx') {
          resolved = CallPath.p2p;
        }
      }
    }
    if (resolved != _path) {
      _path = resolved;
    }
  }

  void dispose() {
    stop();
    _statsController.close();
  }
}
