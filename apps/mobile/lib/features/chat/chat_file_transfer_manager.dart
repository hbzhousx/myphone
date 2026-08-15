/// WebRTC DataChannel 点对点文件/图片/视频传输。
///
/// 文件字节只经数据通道在双方客户端间直传，服务器只中继 offer/answer/ICE 信令，
/// 绝不见文件内容。文件以逐文件随机 AES-256-GCM 密钥加密：发送方加密源文件后
/// 传密文分块，接收方收密文后解密写盘。密钥经棘轮加密的 chatMessage 端到端送达。
///
/// 密文/明文均存 app 私有目录（chat_media/<conversationId>/），服务器不接触。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

import '../../core/crypto/crypto_manager.dart';
import '../../core/webrtc/ice_policy.dart';
import '../../core/webrtc/webrtc_manager.dart';

/// 数据通道背压阈值。
const int _bufferedAmountLow = 64 * 1024;

/// 传输状态回调值。
const String kTransferring = 'transferring';
const String kDone = 'done';
const String kFailed = 'failed';

class ChatFileTransfer {
  final String transferId;
  final String filePath; // 发送：明文源文件；接收：解密后的明文展示文件
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

  /// 把聊天信令发到 WS 的回调（type ∈ chatFileOffer/Answer/Ice）。
  final void Function(String type, Map<String, dynamic> payload)? onSignal;

  /// 诊断上报回调（fire-and-forget，服务器 [CHAT-DIAG] 可见）。
  final void Function(String step, Map<String, dynamic> data)? onDiag;

  rtc.RTCPeerConnection? _pc;
  rtc.RTCDataChannel? _dc;
  ChatFileTransfer? _current;
  Timer? _idleTimer;
  bool _isSender = false;

  // 接收侧暂存：目标明文路径 + AES 密钥 + 密文分块。
  String? _receivePlainPath;
  Uint8List? _receiveAesKey;
  final List<int> _receivedCiphertext = [];

  ChatFileTransferManager({this.onProgress, this.onSignal, this.onDiag});

  /// 发送侧：加密源文件 → 建数据通道 → 发 offer。
  /// [aesKey] 逐文件随机 AES-256-GCM 密钥（32B），[encPath] 本地密文路径。
  /// 传输结束后删除 [encPath] 与源文件临时副本。
  Future<void> sendFile({
    required String transferId,
    required String filePath,
    required String fileName,
    required String mimeType,
    required Uint8List aesKey,
    required String encPath,
  }) async {
    final file = File(filePath);

    // 加密源文件到本地密文（流式分块）。块格式：[4B len][nonce(12)][ciphertext||mac]，
    // 接收方按长度逐块解析，与发送方 chunk 大小无关。
    final encFile = File(encPath);
    await encFile.parent.create(recursive: true);
    final sink = encFile.openWrite();
    final source = file.openRead();
    await for (final chunk in source) {
      final nonce = CryptoManager.randomNonce12();
      final enc = await CryptoManager.aesGcmEncrypt(
        chunk,
        key: aesKey,
        nonce: nonce,
        aad: Uint8List.fromList('myphone-file-v1'.codeUnits),
      );
      final len = enc.length;
      final framed = Uint8List(4 + len)
        ..[0] = (len >> 24) & 0xFF
        ..[1] = (len >> 16) & 0xFF
        ..[2] = (len >> 8) & 0xFF
        ..[3] = len & 0xFF
        ..setRange(4, 4 + len, enc);
      sink.add(framed);
    }
    await sink.close();

    _current = ChatFileTransfer(
      transferId: transferId,
      filePath: encPath, // 数据通道传的是密文文件
      totalBytes: await encFile.length(),
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
  /// [filePath] 解密后明文的落盘路径，[aesKey] 从棘轮加密的 chatMessage 里取出。
  Future<void> handleOffer({
    required String transferId,
    required String sdp,
    required String fileName,
    required int totalBytes,
    required String mimeType,
    required String filePath,
    required Uint8List aesKey,
  }) async {
    // ★先清理旧 PC：前一次传输若未 teardown（连接未断开但传输失败），_pc 残留，
    //   本会话复用旧 PC → 不响应新 offer → 无 answer → 数据通道不建立 → 无法预览。
    if (_pc != null) {
      onDiag?.call('file:reuse-pc', {'transferId': transferId});
      _teardown();
    }
    onDiag?.call('file:offer-start', {'transferId': transferId});
    _current = ChatFileTransfer(
      transferId: transferId,
      filePath: filePath,
      totalBytes: totalBytes,
      fileName: fileName,
      mimeType: mimeType,
    );
    _receivePlainPath = filePath;
    _receiveAesKey = aesKey;
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
    onDiag?.call('file:pc', {
      'policy': policy.name,
      'iceServers': WebrtcManager.defaultIceServers.map((s) => s['urls']).toList().join(','),
      'turnConfigured': WebrtcManager.turnUrl.isNotEmpty,
    });
    final config = <String, dynamic>{
      'iceServers': WebrtcManager.defaultIceServers,
      'sdpSemantics': 'unified-plan',
      'iceTransportPolicy': iceTransportPolicyValue(policy),
    };
    final pc = await rtc.createPeerConnection(config);
    pc.onIceCandidate = (candidate) {
      onDiag?.call('file:ice-cand', {
        'candidate': candidate.candidate ?? 'null',
        'has': candidate.candidate != null && candidate.candidate!.isNotEmpty,
      });
      if (candidate.candidate == null || candidate.candidate!.isEmpty) return;
      onSignal?.call('chatFileIce', {
        'transfer_id': _current?.transferId,
        'candidate': candidate.candidate,
        'sdp_mid': candidate.sdpMid,
        'sdp_mline_index': candidate.sdpMLineIndex,
      });
    };
    pc.onIceConnectionState = (state) {
      onDiag?.call('file:ice-state', {'state': state.name});
    };
    pc.onConnectionState = (state) {
      onDiag?.call('file:conn-state', {'state': state.name});
      if (state == rtc.RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        if (_current != null) {
          onProgress?.call(_current!, 0, kFailed);
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
        if (!_isSender) _finishReceive();
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

  /// 发送密文分块（带 4B 长度头，结尾空帧标记）。
  Future<void> _sendFileStream() async {
    final file = File(_current!.filePath);
    final length = _current!.totalBytes;
    var sent = 0;
    // ★按 .enc 的帧发送：.enc 已是 `[4B len][密文帧]`，不能按 openRead 的
    //   chunk 重新分帧（chunk 边界 ≠ 帧边界 → 接收方按 len 解析错位 → MAC 失败）。
    //   逐帧读取，每帧完整发到数据通道。
    final bytes = await file.readAsBytes();
    try {
      var off = 0;
      while (off + 4 <= bytes.length) {
        final len = (bytes[off] << 24) |
            (bytes[off + 1] << 16) |
            (bytes[off + 2] << 8) |
            bytes[off + 3];
        if (off + 4 + len > bytes.length) break; // 不完整帧，丢弃尾部
        final frame = Uint8List.sublistView(bytes, off, off + 4 + len);
        while (_dc != null &&
            (_dc!.bufferedAmount ?? 0) > _bufferedAmountLow) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        _dc?.send(rtc.RTCDataChannelMessage.fromBinary(frame));
        sent += 4 + len;
        off += 4 + len;
        _current!.transferredBytes = sent;
        onProgress?.call(_current!, sent / length, kTransferring);
      }
      // 结束标记（空帧）。
      if (_dc != null) {
        _dc!.send(rtc.RTCDataChannelMessage.fromBinary(Uint8List(0)));
        onProgress?.call(_current!, 1.0, kDone);
      }
    } catch (e) {
      if (_current != null) onProgress?.call(_current!, 0, kFailed);
    }
  }

  void _receiveChunk(Uint8List data) {
    // 空帧 = 传输结束。发送方用 Uint8List(0)（0 字节）标记结束，
    // 兼容旧 4 字节全 0 空帧。否则接收方收完字节后等不到结束帧，
    // 连接断开 → _finishReceive 不执行 → 文件不写 → 预览失败。
    if (data.isEmpty || (data.length == 4 && data.every((b) => b == 0))) {
      _finishReceive();
      return;
    }
    _receivedCiphertext.addAll(data);
  }

  /// 接收完成：按 `[4B len][密文块]` 逐块解析并解密写盘。
  Future<void> _finishReceive() async {
    final plainPath = _receivePlainPath;
    final aesKey = _receiveAesKey;
    if (_current == null || plainPath == null || aesKey == null) return;
    try {
      final plainFile = File(plainPath);
      await plainFile.parent.create(recursive: true);
      final ciphertext = Uint8List.fromList(_receivedCiphertext);

      final sink = plainFile.openWrite();
      var off = 0;
      while (off + 4 <= ciphertext.length) {
        final len = (ciphertext[off] << 24) |
            (ciphertext[off + 1] << 16) |
            (ciphertext[off + 2] << 8) |
            ciphertext[off + 3];
        if (off + 4 + len > ciphertext.length) break; // 不完整块，丢弃尾部
        final block = Uint8List.sublistView(ciphertext, off + 4, off + 4 + len);
        final dec = await CryptoManager.aesGcmDecrypt(
          block,
          key: aesKey,
          nonceLength: 12,
          aad: Uint8List.fromList('myphone-file-v1'.codeUnits),
        );
        sink.add(dec);
        off += 4 + len;
      }
      await sink.close();
      // 诊断：接收方写盘完成（路径 + 字节数 + 文件是否存在）。
      onDiag?.call('file:receive-done', {
        'path': plainPath,
        'bytes': ciphertext.length,
        'decoded': off,
        'exists': plainFile.existsSync(),
      });

      if (_current != null) onProgress?.call(_current!, 1.0, kDone);
    } catch (e) {
      onDiag?.call('file:receive-fail', {'path': plainPath, 'err': '$e'});
      if (_current != null) onProgress?.call(_current!, 0, kFailed);
    }
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
    _receivePlainPath = null;
    _receiveAesKey = null;
    _receivedCiphertext.clear();
  }

  void dispose() {
    _teardown();
  }
}
