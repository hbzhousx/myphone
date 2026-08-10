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
      double rttMs = 0;
      double packetLoss = 0;
      double jitterMs = 0;
      int count = 0;

      for (final report in stats) {
        if (report.type == 'inbound-rtp' && report.values['kind'] == 'audio') {
          rttMs += (report.values['roundTripTime'] as num? ?? 0).toDouble() * 1000;
          packetLoss += (report.values['packetsLost'] as num? ?? 0).toDouble();
          jitterMs += (report.values['jitter'] as num? ?? 0).toDouble() * 1000;
          count++;
        }
      }

      _resolvePath(stats);

      if (count > 0) {
        rttMs /= count;
        packetLoss /= count;
        jitterMs /= count;

        final networkStats = NetworkStats(
          rttMs: rttMs,
          packetLossPercent: packetLoss,
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
