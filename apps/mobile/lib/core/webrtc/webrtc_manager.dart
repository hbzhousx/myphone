/// WebRTC call engine with Opus codec and DTLS-SRTP encryption.
/// Built on flutter_webrtc.
library;

import 'package:flutter/foundation.dart';
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
  rtc.MediaStream? _remoteStream;

  Function(rtc.RTCIceCandidate candidate)? onIceCandidate;
  Function(rtc.RTCPeerConnectionState state)? onConnectionState;
  Function(rtc.RTCTrackEvent event)? onTrack;

  WebrtcManager({
    List<Map<String, String>> iceServers = const [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
      {
        'urls': 'turn:openrelay.metered.ca:80',
        'username': 'openrelayproject',
        'credential': 'openrelayproject',
      },
    ],
  }) : _iceServers = {
          'iceServers': iceServers,
          'sdpSemantics': 'unified-plan',
          'encodedInsertableStreams': true,
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
      onIceCandidate?.call(candidate);
    };
    _peerConnection!.onConnectionState = (state) {
      debugPrint('[WEBRTC] connectionState: ${state.name}');
      onConnectionState?.call(state);
    };
    _peerConnection!.onIceConnectionState = (state) {
      debugPrint('[WEBRTC] iceConnectionState: ${state.name}');
    };
    _peerConnection!.onIceGatheringState = (state) {
      debugPrint('[WEBRTC] iceGatheringState: ${state.name}');
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
