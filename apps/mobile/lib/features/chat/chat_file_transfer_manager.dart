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

  ChatFileTransfer? _current;
  Timer? _idleTimer;
  bool _isSender = false;

  // 接收侧暂存：目标明文路径 + AES 密钥 + 密文分块。
  String? _receivePlainPath;
  Uint8List? _receiveAesKey;
  final List<int> _receivedCiphertext = [];

  // ---- 传输串行化（单传输模型）----
  // 管理器一次只支持一个活动传输。连发/连收时若新传输不等上一个结束就 teardown，
  // 会掐断上一个正在传输的 PC → 接收方拿到 0 字节空文件 → 无法预览。
  // 用 turn 链串行化：新传输开始前必须等上一个彻底结束。
  Completer<void>? _turnDone; // 当前传输完成信号（数据帧发完/收完）
  rtc.RTCPeerConnection? _turnPc; // 当前 turn 的 PC（识别陈旧事件）
  rtc.RTCDataChannel? _turnDc; // 当前 turn 的 DC（识别陈旧事件）

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
    // ★串行化：单传输模型。必须等上一个传输（含进行中接收）彻底结束再开新 turn，
    //   否则 teardown 会掐断上一个正在传输的 PC → 接收方拿到 0 字节空文件。
    if (_turnDone != null) {
      onDiag?.call('file:queue-wait', {'transferId': transferId});
      await _turnDone!.future;
    }

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
    _startTurn();

    final pc = await _createPeerConnection();
    final dc = await pc.createDataChannel('myphone-files', rtc.RTCDataChannelInit());
    _turnDc = dc;
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
    // ★串行化：单传输模型。若上一个传输仍在进行（连发多张图/收发并发），
    //   必须等其结束再开新 PC，否则 teardown 掐断上一个 → 接收方拿 0 字节空文件。
    if (_turnDone != null) {
      onDiag?.call('file:queue-wait', {'transferId': transferId});
      await _turnDone!.future;
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
    _startTurn();

    final pc = await _createPeerConnection();
    pc.onDataChannel = (channel) {
      _turnDc = channel;
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
    if (_turnPc == null) return;
    await _turnPc!.addCandidate(rtc.RTCIceCandidate(
      candidate['candidate'] as String? ?? '',
      candidate['sdp_mid'] as String? ?? '',
      candidate['sdp_mline_index'] as int? ?? 0,
    ));
  }

  /// 处理入站 answer（offer 方设置远端描述后 ICE 开始）。
  Future<void> handleAnswer(String transferId, String sdp) async {
    if (_turnPc == null) return;
    await _turnPc!.setRemoteDescription(rtc.RTCSessionDescription(sdp, 'answer'));
  }

  Future<rtc.RTCPeerConnection> _createPeerConnection() async {
    if (_turnPc != null) return _turnPc!;
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
      // 陈旧 PC 事件（上一个 turn 的 PC 已在 endTurn 里 close）——忽略。
      if (_turnPc != pc) return;
      onDiag?.call('file:conn-state', {'state': state.name});
      if (state == rtc.RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        if (_current != null) {
          onProgress?.call(_current!, 0, kFailed);
        }
        // 断开即本 turn 失败：close 并放行队列（_endTurn complete turn 信号）。
        _endTurn();
      }
    };
    _turnPc = pc;
    return pc;
  }

  void _setupDataChannel(rtc.RTCDataChannel dc) {
    _turnDc = dc;
    dc.stateChangeStream.listen((state) {
      // 陈旧 DC 事件（上一个 turn 的 DC 已在 teardown 里 close，但 listener 仍
      // 残留）——忽略，避免误触发 finishReceive/teardown 干扰新 turn。
      if (_turnDc != dc) return;
      if (state == rtc.RTCDataChannelState.RTCDataChannelOpen) {
        _idleTimer?.cancel();
        if (_isSender) {
          _sendFileStream();
        }
      } else if (state == rtc.RTCDataChannelState.RTCDataChannelClosed) {
        if (!_isSender) _finishReceive();
        _endTurn();
      }
    });
    dc.messageStream.listen((message) {
      if (_turnDc != dc) return;
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
        while (_turnDc != null &&
            (_turnDc!.bufferedAmount ?? 0) > _bufferedAmountLow) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        _turnDc?.send(rtc.RTCDataChannelMessage.fromBinary(frame));
        sent += 4 + len;
        off += 4 + len;
        _current!.transferredBytes = sent;
        onProgress?.call(_current!, sent / length, kTransferring);
      }
      // 结束标记（空帧）。
      if (_turnDc != null) {
        _turnDc!.send(rtc.RTCDataChannelMessage.fromBinary(Uint8List(0)));
        onProgress?.call(_current!, 1.0, kDone);
      }
      // ★发送完成 ≠ turn 结束：不能在这里 _endTurn 关 PC——接收方可能仍在
      //   收数据（PC 刚 Connected）。提前关 PC → 接收方 PC 立即 Closed/Disconnected
      //   → _finishReceive 拿到空数据 → 0 字节文件无法预览。
      //   正确时机：接收方收完空帧 → _finishReceive 写盘 → 主动关 DC →
      //   发送方看到 DC Closed → _setupDataChannel 里 _endTurn 放行队列。
      // 兜底：对端异常关闭时 DC Closed 也会触发 _endTurn；此处仅失败才立即结束。
    } catch (e) {
      if (_current != null) onProgress?.call(_current!, 0, kFailed);
      _endTurn();
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
      // 接收完成 → 结束当前 turn（放行排队中的下一个传输）。
      _endTurn();
    } catch (e) {
      onDiag?.call('file:receive-fail', {'path': plainPath, 'err': '$e'});
      if (_current != null) onProgress?.call(_current!, 0, kFailed);
      _endTurn();
    }
  }

  /// 结束当前 turn：关闭 PC/DC、清空状态、完成 turn 信号放行队列。
  /// 与 _teardown（仅连接断开时用）不同：_endTurn 是数据层面完成/失败后调用，
  /// 必须完成 _turnDone 让排队中的下一个传输开始。
  void _endTurn() {
    _idleTimer?.cancel();
    try {
      _turnDc?.close();
    } catch (_) {}
    _turnDc = null;
    _turnPc?.close();
    _turnPc = null;
    _current = null;
    _receivePlainPath = null;
    _receiveAesKey = null;
    _receivedCiphertext.clear();
    if (_turnDone != null && !_turnDone!.isCompleted) {
      _turnDone!.complete();
    }
    _turnDone = null;
  }

  /// 开始一个新 turn：登记完成信号（供后续传输 await）。
  void _startTurn() {
    _turnDone = Completer<void>();
  }

  void dispose() {
    _endTurn();
  }
}
