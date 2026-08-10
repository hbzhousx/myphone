/// WebRTC call engine with Opus codec and DTLS-SRTP encryption.
/// Built on flutter_webrtc.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import 'ice_policy.dart';

enum NetworkTier { excellent, good, moderate, poor }

class OpusConfig {
  final int bitrateBps;
  final int sampleRate;
  final int frameSizeMs;
  final bool fec;
  final bool dtx;
  final int complexity;

  const OpusConfig({
    required this.bitrateBps,
    required this.sampleRate,
    required this.frameSizeMs,
    required this.fec,
    required this.dtx,
    required this.complexity,
  });

  factory OpusConfig.forTier(NetworkTier tier) {
    switch (tier) {
      case NetworkTier.excellent:
        return const OpusConfig(
          bitrateBps: 48000, sampleRate: 16000, frameSizeMs: 20,
          fec: false, dtx: false, complexity: 5,
        );
      case NetworkTier.good:
        return const OpusConfig(
          bitrateBps: 32000, sampleRate: 16000, frameSizeMs: 20,
          fec: false, dtx: false, complexity: 5,
        );
      case NetworkTier.moderate:
        return const OpusConfig(
          bitrateBps: 12000, sampleRate: 8000, frameSizeMs: 20,
          fec: true, dtx: true, complexity: 4,
        );
      case NetworkTier.poor:
        return const OpusConfig(
          bitrateBps: 6000, sampleRate: 8000, frameSizeMs: 40,
          fec: true, dtx: true, complexity: 3,
        );
    }
  }
}

/// 呼叫诊断信息，用于在 CallScreen 实时显示，帮助排查媒体建立问题。
class CallDiagnostics {
  String connectionState = 'idle'; // RTCPeerConnectionState
  String iceConnectionState = 'new'; // RTCIceConnectionState
  String iceGatheringState = 'new'; // RTCIceGatheringState
  final List<String> localCandidates = []; // 本地候选，含类型 (host/srflx/relay)
  final List<String> timeline = []; // 事件时间线（最多保留 ~20 条）

  /// 从 RTCIceCandidate.candidate 字符串解析候选类型。
  static String typeOf(String candidate) {
    final m = RegExp(r'\btyp\s+(\w+)').firstMatch(candidate);
    return m?.group(1) ?? 'unknown';
  }
}

class WebrtcManager {
  rtc.RTCPeerConnection? _peerConnection;
  rtc.MediaStream? _localStream;
  final Map<String, dynamic> _iceServers;
  rtc.MediaStream? _remoteStream;

  Function(rtc.RTCIceCandidate candidate)? onIceCandidate;
  Function(rtc.RTCPeerConnectionState state)? onConnectionState;
  Function(rtc.RTCTrackEvent event)? onTrack;

  /// 诊断信息（独立于 Riverpod 状态流，供 CallScreen 实时监听）。
  final ValueNotifier<CallDiagnostics> diagnostics = ValueNotifier(CallDiagnostics());

  /// 追加一条诊断时间线事件。
  void log(String event) {
    final d = diagnostics.value;
    d.timeline.add(event);
    if (d.timeline.length > 20) {
      d.timeline.removeRange(0, d.timeline.length - 20);
    }
    diagnostics.value = CallDiagnostics()
      ..connectionState = d.connectionState
      ..iceConnectionState = d.iceConnectionState
      ..iceGatheringState = d.iceGatheringState
      ..localCandidates.addAll(d.localCandidates)
      ..timeline.addAll(d.timeline);
    _appendToLogFile('${_timestamp()} $event');
  }

  static Future<String>? _logFilePath;
  static Future<String> _resolveLogPath() async {
    // 写入 USB/文件管理器可访问的目录：/storage/emulated/0/Android/data/com.myphone.app/files/
    // （真机上通过 USB 连接即可看到；不要用 getApplicationDocumentsDirectory()——那是 App 私有目录，普通访问不到）
    final dir = await getExternalStorageDirectory();
    if (dir != null) {
      return p.join(dir.path, 'Android', 'data', 'com.myphone.app', 'files', 'myphone_diag.log');
    }
    final appDir = await getApplicationDocumentsDirectory();
    return p.join(appDir.path, 'myphone_diag.log');
  }

  static String _timestamp() {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(n.hour)}:${two(n.minute)}:${two(n.second)}.${(n.millisecond ~/ 100)}';
  }

  static void _appendToLogFile(String line) {
    unawaited(() async {
      try {
        final path = await (_logFilePath ??= _resolveLogPath());
        final f = File(path);
        await f.parent.create(recursive: true);
        await f.writeAsString('$line\n', mode: FileMode.append);
      } catch (e) {
        debugPrint('[WEBRTC] log file write failed: $e');
      }
    }());
  }

  /// 生产环境 ICE 服务器，通过 --dart-define 注入自建 STUN/TURN；
  /// 未配置时回退到默认的 Google STUN + Metered TURN（仅适合开发联调）。
  static const String _stunUrl = String.fromEnvironment(
    'MYPHONE_STUN_URL',
    defaultValue: 'stun:stun.l.google.com:19302',
  );
  static const String _turnUrl = String.fromEnvironment('MYPHONE_TURN_URL');
  static const String _turnUsername = String.fromEnvironment('MYPHONE_TURN_USERNAME');
  static const String _turnCredential = String.fromEnvironment('MYPHONE_TURN_CREDENTIAL');

  /// 供呼叫前自适应 ICE 探测使用(ice_policy.dart 的 determineIcePolicy)。
  static String get stunUrl => _stunUrl;
  static String get turnUrl => _turnUrl;

  /// 编译期决定的 ICE 服务器列表。
  static const List<Map<String, String>> defaultIceServers = _turnUrl == ''
      ? [
          {'urls': 'stun:stun.l.google.com:19302'},
          {'urls': 'stun:stun1.l.google.com:19302'},
          {
            'urls': 'turn:openrelay.metered.ca:80',
            'username': 'openrelayproject',
            'credential': 'openrelayproject',
          },
        ]
      : [
          {'urls': _stunUrl},
          {'urls': _turnUrl, 'username': _turnUsername, 'credential': _turnCredential},
        ];

  WebrtcManager({
    List<Map<String, String>> iceServers = defaultIceServers,
    IcePolicy policy = IcePolicy.auto,
  }) : _iceServers = {
          'iceServers': iceServers,
          'sdpSemantics': 'unified-plan',
          'encodedInsertableStreams': true,
          // 自适应 ICE 策略：p2p=all(先试 host/srflx 直连，不通 ICE 自动 fallback relay)；
          // relay=强制走 TURN(经 TCP，适用于手机 UDP 受限场景)。
          // 由调用方在呼叫前用 determineIcePolicy() 探测决定；auto 默认 all。
          'iceTransportPolicy': iceTransportPolicyValue(policy),
        };

  rtc.RTCPeerConnection? get peerConnection => _peerConnection;
  rtc.MediaStream? get localStream => _localStream;
  rtc.MediaStream? get remoteStream => _remoteStream;

  Future<void> initialize() async {
    try {
      _localStream = await rtc.navigator.mediaDevices
          .getUserMedia({
            'audio': {
              'echoCancellation': true,
              'noiseSuppression': true,
              'autoGainControl': true,
            },
            'video': false,
          })
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      debugPrint('[WEBRTC] getUserMedia failed: $e');
      rethrow;
    }

    _peerConnection = await rtc.createPeerConnection(_iceServers);

    _localStream!.getAudioTracks().forEach((track) {
      _peerConnection!.addTrack(track, _localStream!);
    });

    _peerConnection!.onIceCandidate = (candidate) {
      if (candidate.candidate == null) {
        return;
      }
      // 记录本地 ICE 候选类型（host/srflx/relay/prflx），供诊断面板显示。
      final d = diagnostics.value;
      final type = CallDiagnostics.typeOf(candidate.candidate!);
      final label = '$type:${candidate.candidate}';
      if (!d.localCandidates.contains(label) && d.localCandidates.length < 8) {
        d.localCandidates.add(label);
      }
      log('local ICE: $type');
      onIceCandidate?.call(candidate);
    };
    _peerConnection!.onConnectionState = (state) {
      debugPrint('[WEBRTC] connectionState: ${state.name}');
      diagnostics.value.connectionState = state.name;
      log('peerConnection: ${state.name}');
      onConnectionState?.call(state);
    };
    _peerConnection!.onIceConnectionState = (state) {
      debugPrint('[WEBRTC] iceConnectionState: ${state.name}');
      diagnostics.value.iceConnectionState = state.name;
      log('iceConnection: ${state.name}');
    };
    _peerConnection!.onIceGatheringState = (state) {
      debugPrint('[WEBRTC] iceGatheringState: ${state.name}');
      diagnostics.value.iceGatheringState = state.name;
      log('iceGathering: ${state.name}');
    };
    _peerConnection!.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        _remoteStream = event.streams.first;
      }
      onTrack?.call(event);
    };
  }

  Future<String> createOffer() async {
    final offer = await _peerConnection!.createOffer({
      'offerToReceiveAudio': true,
      'offerToReceiveVideo': false,
    });
    await _peerConnection!.setLocalDescription(offer);
    return offer.sdp!;
  }

  Future<String> createAnswer() async {
    final answer = await _peerConnection!.createAnswer({
      'offerToReceiveAudio': true,
      'offerToReceiveVideo': false,
    });
    await _peerConnection!.setLocalDescription(answer);
    return answer.sdp!;
  }

  Future<void> setRemoteDescription(String sdp, String type) async {
    await _peerConnection!.setRemoteDescription(
      rtc.RTCSessionDescription(sdp, type),
    );
  }

  Future<void> addIceCandidate(String candidate, String sdpMid, int sdpMLineIndex) async {
    await _peerConnection!.addCandidate(rtc.RTCIceCandidate(
      candidate, sdpMid, sdpMLineIndex,
    ));
  }

  void adaptBitrate(NetworkTier tier) {
    final config = OpusConfig.forTier(tier);
    _applyOpusConfig(config);
  }

  Future<void> _applyOpusConfig(OpusConfig config) async {
    final pc = _peerConnection;
    if (pc == null) return;

    try {
      final senders = await pc.getSenders();
      for (final sender in senders) {
        final track = sender.track;
        if (track == null || track.kind != 'audio') continue;

        try {
          final parameters = sender.parameters;
          final encodings = parameters.encodings;
          if (encodings != null && encodings.isNotEmpty) {
            // maxBitrate in kbps (flutter_webrtc convention)
            encodings[0].maxBitrate = config.bitrateBps ~/ 1000;
            await sender.setParameters(parameters);
          }
        } catch (e) {
          debugPrint('adaptBitrate: setParameters failed for sender: $e');
        }
      }
    } catch (e) {
      debugPrint('adaptBitrate: getSenders failed: $e');
    }
  }

  // --- Mute ---

  bool _isMuted = false;
  bool get isMuted => _isMuted;

  void mute() {
    if (_isMuted) return;
    _isMuted = true;
    final audioTracks = _localStream?.getAudioTracks() ?? [];
    for (final track in audioTracks) {
      track.enabled = false;
    }
  }

  void unmute() {
    if (!_isMuted) return;
    _isMuted = false;
    final audioTracks = _localStream?.getAudioTracks() ?? [];
    for (final track in audioTracks) {
      track.enabled = true;
    }
  }

  void toggleMute() {
    if (_isMuted) {
      unmute();
    } else {
      mute();
    }
  }

  // --- Speaker ---

  bool _speakerOn = false;
  bool get isSpeakerOn => _speakerOn;

  Future<void> setSpeakerOn(bool on) async {
    try {
      await rtc.Helper.setSpeakerphoneOn(on);
      _speakerOn = on;
    } catch (e) {
      // Graceful degradation — not all platforms support speaker toggle
    }
  }

  Future<void> toggleSpeaker() async {
    await setSpeakerOn(!_speakerOn);
  }

  Future<void> hangup() async {
    _localStream?.getTracks().forEach((track) => track.stop());
    _remoteStream?.getTracks().forEach((track) => track.stop());
    await _peerConnection?.close();
    _peerConnection = null;
    _localStream = null;
    _remoteStream = null;
  }
}
