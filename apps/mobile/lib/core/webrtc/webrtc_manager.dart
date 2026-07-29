/// WebRTC call engine with Opus codec and DTLS-SRTP encryption.
/// Built on flutter_webrtc.
library;

import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

enum NetworkTier { good, moderate, poor }

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

class WebrtcManager {
  rtc.RTCPeerConnection? _peerConnection;
  rtc.MediaStream? _localStream;
  final Map<String, dynamic> _iceServers;

  WebrtcManager({
    List<Map<String, String>> iceServers = const [
      {'urls': 'stun:stun.l.google.com:19302'},
    ],
  }) : _iceServers = {'iceServers': iceServers};

  rtc.RTCPeerConnection? get peerConnection => _peerConnection;
  rtc.MediaStream? get localStream => _localStream;

  Future<void> initialize() async {
    _localStream = await rtc.navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': false,
    });

    _peerConnection = await rtc.createPeerConnection(_iceServers);

    _localStream!.getAudioTracks().forEach((track) {
      _peerConnection!.addTrack(track, _localStream!);
    });

    _peerConnection!.onTrack = (_) {};
  }

  Future<String> createOffer() async {
    final offer = await _peerConnection!.createOffer({
      'offerToReceiveAudio': true,
      'offerToReceiveVideo': false,
    });
    final modifiedSdp = _configureOpusSdp(offer.sdp!, NetworkTier.moderate);
    await _peerConnection!.setLocalDescription(
      rtc.RTCSessionDescription(offer.type, modifiedSdp),
    );
    return modifiedSdp;
  }

  Future<String> createAnswer() async {
    final answer = await _peerConnection!.createAnswer({
      'offerToReceiveAudio': true,
      'offerToReceiveVideo': false,
    });
    final modifiedSdp = _configureOpusSdp(answer.sdp!, NetworkTier.moderate);
    await _peerConnection!.setLocalDescription(
      rtc.RTCSessionDescription(answer.type, modifiedSdp),
    );
    return modifiedSdp;
  }

  Future<void> setRemoteDescription(String sdp, String type) async {
    await _peerConnection!.setRemoteDescription(
      rtc.RTCSessionDescription(type, sdp),
    );
  }

  Future<void> addIceCandidate(String candidate, String sdpMid, int sdpMLineIndex) async {
    await _peerConnection!.addCandidate(rtc.RTCIceCandidate(
      candidate, sdpMid, sdpMLineIndex,
    ));
  }

  void adaptBitrate(NetworkTier tier) {
    // Dynamically reconfigure Opus encoder via RTCRtpSender.setParameters
  }

  String _configureOpusSdp(String sdp, NetworkTier tier) {
    final config = OpusConfig.forTier(tier);
    final lines = sdp.split('\r\n');
    final result = <String>[];
    int? opusPayloadType;

    for (final line in lines) {
      if (line.startsWith('a=rtpmap:') && line.contains('opus/48000/2')) {
        opusPayloadType = int.tryParse(line.substring(9, line.indexOf(' ')));
      }
      if (line.startsWith('a=rtpmap:') && line.contains('audio') && !line.contains('opus')) {
        continue;
      }
      result.add(line);
    }

    if (opusPayloadType != null) {
      result.add('a=fmtp:$opusPayloadType '
          'minptime=10;'
          'useinbandfec=${config.fec ? 1 : 0};'
          'usedtx=${config.dtx ? 1 : 0};'
          'maxaveragebitrate=${config.bitrateBps};'
          'stereo=0;'
          'sprop-stereo=0');
    }

    return result.join('\r\n');
  }

  Future<void> hangup() async {
    _localStream?.getTracks().forEach((track) => track.stop());
    await _peerConnection?.close();
    _peerConnection = null;
    _localStream = null;
  }
}
