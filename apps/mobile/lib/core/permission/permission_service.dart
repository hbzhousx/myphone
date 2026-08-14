/// 权限引导：首次进入聊天/通话相关页面时申请对应权限。
///
/// 与「启动时一次性全部申请」相比，改成按场景引导，让用户理解为什么需要权限，
/// 且适配各机型（Android 6+ 运行时动态授权，photo picker/SAF 无需存储权限）。
library;

import 'package:flutter/material.dart';
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
}
