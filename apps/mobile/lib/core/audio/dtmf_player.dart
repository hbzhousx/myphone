/// DTMF 拨号音播放器:点击拨号键盘按键时播放对应的双音多频(DTMF)短音。
///
/// 用 audioplayers 播放打包在 assets/sounds/dtmf/ 的 12 个 wav(0-9,*,#)。
/// 使用单个 AudioPlayer 实例,快速连续按键时丢弃旧播放(只响最新一次),避免重叠噪音。
library;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

class DtmfPlayer {
  static final AudioPlayer _player = AudioPlayer();
  static bool _disposed = false;

  static String _assetFor(String digit) {
    final name = switch (digit) {
      '*' => 'star',
      '#' => 'hash',
      _ => digit,
    };
    return 'assets/sounds/dtmf/dtmf_$name.wav';
  }

  /// 播放一个按键音。非数字键(如删除/呼叫)可传空或直接不调用。
  static Future<void> playDigit(String digit) async {
    if (_disposed || digit.isEmpty) return;
    try {
      // 用 stop 丢弃上一条未播完的音,避免快速按键时叠音。
      await _player.stop();
      await _player.play(AssetSource(_assetFor(digit)),
          volume: 0.8, mode: PlayerMode.lowLatency);
    } catch (e) {
      if (kDebugMode) debugPrint('[DTMF] play $digit error: $e');
    }
  }

  static Future<void> dispose() async {
    _disposed = true;
    await _player.dispose();
  }
}
