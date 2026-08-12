/// WebRTC DataChannel 点对点文件/图片/视频传输。
///
/// 文件字节只经数据通道在双方客户端间直传，服务器只中继 offer/answer/ICE 信令，
/// 绝不见文件内容。文件以逐文件随机 AES-256-GCM 密钥加密，密钥经棘轮加密的
/// chatMessage 端到端送达对端。发送方/接收方各自把密文存 app 私有目录。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

import '../../core/webrtc/ice_policy.dart';
import '../../core/webrtc/webrtc_manager.dart';

/// 数据通道背压阈值。
const int _bufferedAmountLow = 64 * 1024;

class ChatFileTransfer {
  final String transferId;
  final String filePath; // 源文件（发送）或密文文件（接收）
  final int totalBytes;
  final String fileName;
  final String mimeType;
  int transferredBytes;

  ChatFileTransfer({
    required this.transferId,
    required this.filePath,
    required this.totalBytes,
    required this.fileName,
    required this.mimeType,
    this.transferredBytes = 0,
  });
}

/// 数据通道文件传输管理器（每个活跃传输一个实例）。
class ChatFileTransferManager {
  /// 进度回调：传输中 / 完成 / 失败。
  final void Function(ChatFileTransfer transfer, double progress, String status)?
      onProgress;

  /// 把聊天信令发到 WS 的回调（type ∈ chatFileOffer/Answer/Ice/Done）。
  final void Function(String type, Map<String, dynamic> payload)? onSignal;

  rtc.RTCPeerConnection? _pc;
  rtc.RTCDataChannel? _dc;
  ChatFileTransfer? _current;
  Timer? _idleTimer;
  bool _isSender = false;
  final List<int> _receiveBuffer = [];

  ChatFileTransferManager({this.onProgress, this.onSignal});

  /// 发送侧：初始化数据通道连接并发出 offer。
  Future<void> sendFile({
    required String transferId,
    required String filePath,
    required String fileName,
    required String mimeType,
  }) async {
    final file = File(filePath);
    final size = await file.length();
    _current = ChatFileTransfer(
      transferId: transferId,
      filePath: filePath,
      totalBytes: size,
      fileName: fileName,
      mimeType: mimeType,
    );
    _isSender = true;

    final pc = await _createPeerConnection();
    final dc = await pc.createDataChannel('myphone-files', rtc.RTCDataChannelInit());
    _dc = dc;
    _setupDataChannel(dc);

    final offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    onSignal?.call('chatFileOffer', {
      'transfer_id': transferId,
      'sdp': offer.sdp,
      'type': 'offer',
    });
  }

  /// 接收侧：处理入站 offer，回 answer。
  Future<void> handleOffer({
    required String transferId,
    required String sdp,
    required String fileName,
    required int totalBytes,
    required String mimeType,
  }) async {
    _current = ChatFileTransfer(
      transferId: transferId,
      filePath: '',
      totalBytes: totalBytes,
      fileName: fileName,
      mimeType: mimeType,
    );
    _isSender = false;

    final pc = await _createPeerConnection();
    pc.onDataChannel = (channel) {
      _dc = channel;
      _setupDataChannel(channel);
    };
    await pc.setRemoteDescription(rtc.RTCSessionDescription(sdp, 'offer'));
    final answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);
    onSignal?.call('chatFileAnswer', {
      'transfer_id': transferId,
      'sdp': answer.sdp,
      'type': 'answer',
    });
  }

  /// 处理入站 ICE candidate。
  Future<void> handleIceCandidate(
      String transferId, Map<String, dynamic> candidate) async {
    if (_pc == null) return;
    await _pc!.addCandidate(rtc.RTCIceCandidate(
      candidate['candidate'] as String? ?? '',
      candidate['sdp_mid'] as String? ?? '',
      candidate['sdp_mline_index'] as int? ?? 0,
    ));
  }

  /// 处理入站 answer（offer 方设置远端描述后 ICE 开始）。
  Future<void> handleAnswer(String transferId, String sdp) async {
    if (_pc == null) return;
    await _pc!.setRemoteDescription(rtc.RTCSessionDescription(sdp, 'answer'));
  }

  Future<rtc.RTCPeerConnection> _createPeerConnection() async {
    if (_pc != null) return _pc!;
    final policy = await determineIcePolicy();
    final config = <String, dynamic>{
      'iceServers': WebrtcManager.defaultIceServers,
      'sdpSemantics': 'unified-plan',
      'iceTransportPolicy': iceTransportPolicyValue(policy),
    };
    final pc = await rtc.createPeerConnection(config);
    pc.onIceCandidate = (candidate) {
      if (candidate.candidate == null || candidate.candidate!.isEmpty) return;
      onSignal?.call('chatFileIce', {
        'transfer_id': _current?.transferId,
        'candidate': candidate.candidate,
        'sdp_mid': candidate.sdpMid,
        'sdp_mline_index': candidate.sdpMLineIndex,
      });
    };
    pc.onConnectionState = (state) {
      if (state == rtc.RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        if (_current != null) {
          onProgress?.call(_current!, 0, 'failed');
        }
        _teardown();
      }
    };
    _pc = pc;
    return pc;
  }

  void _setupDataChannel(rtc.RTCDataChannel dc) {
    dc.stateChangeStream.listen((state) {
      if (state == rtc.RTCDataChannelState.RTCDataChannelOpen) {
        _idleTimer?.cancel();
        if (_isSender) {
          _sendFileStream();
        }
      } else if (state == rtc.RTCDataChannelState.RTCDataChannelClosed) {
        if (!_isSender) _writeReceivedFile();
        _teardown();
      }
    });
    dc.messageStream.listen((message) {
      _idleTimer?.cancel();
      if (!_isSender && message.isBinary) {
        _receiveChunk(message.binary);
      }
    });
  }

  Future<void> _sendFileStream() async {
    final file = File(_current!.filePath);
    final length = _current!.totalBytes;
    var sent = 0;
    final stream = file.openRead();
    await for (final chunk in stream) {
      while (_dc != null &&
          (_dc!.bufferedAmount ?? 0) > _bufferedAmountLow) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      final len = chunk.length;
      final frame = Uint8List(4 + len);
      frame[0] = (len >> 24) & 0xFF;
      frame[1] = (len >> 16) & 0xFF;
      frame[2] = (len >> 8) & 0xFF;
      frame[3] = len & 0xFF;
      frame.setRange(4, 4 + len, chunk);
      _dc?.send(rtc.RTCDataChannelMessage.fromBinary(frame));
      sent += len;
      _current!.transferredBytes = sent;
      onProgress?.call(_current!, sent / length, 'transferring');
    }
    // 结束标记（空帧）。
    if (_dc != null) {
      _dc!.send(rtc.RTCDataChannelMessage.fromBinary(Uint8List(0)));
      onProgress?.call(_current!, 1.0, 'done');
    }
  }

  void _receiveChunk(Uint8List data) {
    if (data.length == 4 && data.every((b) => b == 0)) {
      _writeReceivedFile();
      return;
    }
    _receiveBuffer.addAll(data);
  }

  Future<void> _writeReceivedFile() async {
    if (_current == null || _current!.filePath.isEmpty) return;
    final file = File(_current!.filePath);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(Uint8List.fromList(_receiveBuffer));
    onProgress?.call(_current!, 1.0, 'done');
    _teardown();
  }

  void _teardown() {
    _idleTimer?.cancel();
    try {
      _dc?.close();
    } catch (_) {}
    _dc = null;
    _pc?.close();
    _pc = null;
    _current = null;
    _receiveBuffer.clear();
  }

  void dispose() {
    _teardown();
  }
}
