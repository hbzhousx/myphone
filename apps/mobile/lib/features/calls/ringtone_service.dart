/// Ringtone playback using system ringtone/notification sounds.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';

class RingtoneService {
  static final _player = FlutterRingtonePlayer();
  static bool _isPlaying = false;
  static bool get isPlaying => _isPlaying;

  static void _log(String msg) {
    if (kDebugMode) debugPrint('[RINGTONE] $msg');
  }

  /// Play ringback tone (heard by the caller while waiting).
  static void playRingback() {
    if (_isPlaying) return;
    _isPlaying = true;
    _log('playRingback starting');
    _player.playRingtone(volume: 0.5, looping: true).catchError((e) {
      _log('playRingback error: $e');
      _isPlaying = false;
    });
  }

  /// Play incoming ringtone (heard by the callee).
  static void playRingtone() {
    if (_isPlaying) return;
    _isPlaying = true;
    _log('playRingtone starting');
    _player.playRingtone(volume: 0.7, looping: true).catchError((e) {
      _log('playRingtone error: $e');
      _isPlaying = false;
    });
  }

  /// Stop any playing ringtone.
  static void stop() {
    _isPlaying = false;
    _player.stop().catchError((_) {});
  }

  /// Play a short "number not found" beep (heard by the caller).
  static void playNumberNotFound() {
    if (_isPlaying) return;
    _isPlaying = true;
    _log('playNumberNotFound starting');
    // Use the system notification sound as a short, non-looping tone.
    _player.play(volume: 0.7).then((_) {
      _isPlaying = false;
    }).catchError((e) {
      _log('playNumberNotFound error: $e');
      _isPlaying = false;
    });
  }
}
