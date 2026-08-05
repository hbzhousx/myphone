/// Monitors network quality (RTT, packet loss, jitter) during calls
/// and adapts the Opus encoder configuration in real-time.
library;

import 'dart:async';
import 'webrtc_manager.dart';

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
    if (rttMs < 100 && packetLossPercent < 2) return NetworkTier.good;
    if (rttMs < 500 && packetLossPercent < 10) return NetworkTier.moderate;
    return NetworkTier.poor;
  }
}

class NetworkMonitor {
  final WebrtcManager _webrtcManager;
  Timer? _monitorTimer;
  NetworkTier _currentTier = NetworkTier.good;

  final _statsController = StreamController<NetworkStats>.broadcast();
  Stream<NetworkStats> get stats => _statsController.stream;
  NetworkTier get currentTier => _currentTier;

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

  void dispose() {
    stop();
    _statsController.close();
  }
}
