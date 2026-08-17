/// 权限引导：首次进入聊天/通话相关页面时申请对应权限。
///
/// 与「启动时一次性全部申请」相比，改成按场景引导，让用户理解为什么需要权限，
/// 且适配各机型（Android 6+ 运行时动态授权，photo picker/SAF 无需存储权限）。
library;

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

class PermissionService {
  /// 首次进入聊天页时申请权限。直接触发系统授权框（Signal 做法：不搞中间引导层，
  /// 用户看到的就是系统"允许/拒绝"）。已授权则跳过。仅请求相机（拍照必需），
  /// 图库/文件走系统 picker 无需额外权限。
  static Future<void> ensureChatPermissions(BuildContext context) async {
    // 仅当未授权时才触发系统框，避免每次都弹。
    if (await Permission.camera.isGranted) return;
    await Permission.camera.request();
    // 通知（收到新消息提示），未授权才请求。
    if (!await Permission.notification.isGranted) {
      await Permission.notification.request();
    }
  }

  /// 首次进入通话页时申请麦克风（通话必需）。直接触发系统授权框。
  static Future<bool> ensureCallPermissions(BuildContext context) async {
    if (await Permission.microphone.isGranted) return true;
    final status = await Permission.microphone.request();
    return status.isGranted;
  }

  /// 申请通知权限（来电全屏/新消息提示必需）。已授权则跳过。
  /// ★P0-B：主路径（拨号盘/常驻开关）调用，避免用户不进聊天页则通知权限从未申请。
  static Future<bool> ensureIncomingCallNotifications() async {
    if (!Platform.isAndroid) return true;
    if (await Permission.notification.isGranted) return true;
    final status = await Permission.notification.request();
    return status.isGranted;
  }

  /// Android 14+ 是否有"全屏通知"权限（决定来电能否全屏唤醒）。
  /// 非 Android 或 <34 视为允许。复用 myphone/system 原生通道。
  static const MethodChannel _systemChannel = MethodChannel('myphone/system');

  static Future<bool> canUseFullScreenIntent() async {
    if (!Platform.isAndroid) return true;
    try {
      final r = await _systemChannel.invokeMethod('getFullScreenIntentStatus');
      if (r is Map) return r['allowed'] == true;
      return true;
    } catch (_) {
      return true;
    }
  }

  /// 跳转系统"全屏通知"设置页（Android 14+，用户手动开启 FSI）。
  static Future<void> openFullScreenIntentSettings() async {
    try {
      await _systemChannel.invokeMethod('openFullScreenIntentSettings');
    } catch (_) {}
  }

  /// 跳转本应用通知设置页（通知权限被拒后引导用户手动开启）。
  static Future<void> openNotificationSettings() async {
    try {
      await _systemChannel.invokeMethod('openNotificationSettings');
    } catch (_) {}
  }

  /// 请求"忽略电池优化"（弹系统确认框一键授权）。返回 true=已豁免/已弹框。
  /// 失败（部分 ROM 移除该弹框）时 Flutter 回退跳厂商自启动页。
  static Future<bool> requestIgnoreBatteryOptimization() async {
    if (!Platform.isAndroid) return true;
    try {
      final r = await _systemChannel.invokeMethod('requestIgnoreBatteryOptimization');
      return r == 'already' || r == 'requested';
    } catch (_) {
      return false;
    }
  }
}
