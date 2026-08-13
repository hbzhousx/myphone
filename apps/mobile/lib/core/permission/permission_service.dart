/// 权限引导：首次进入聊天/通话相关页面时申请对应权限。
///
/// 与「启动时一次性全部申请」相比，改成按场景引导，让用户理解为什么需要权限，
/// 且适配各机型（Android 6+ 运行时动态授权，photo picker/SAF 无需存储权限）。
library;

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

class PermissionService {
  /// 首次进入聊天页时引导：请求相机（拍照）+ 存储（图库/文件，旧机型）。
  /// 图库/文件在 Android 13+ 走系统 picker 无需权限，仅在旧机型请求 storage。
  static Future<bool> ensureChatPermissions(BuildContext context) async {
    // 引导对话框：先解释，再触发系统授权。
    final go = await _showGuide(
      context,
      title: '开启相机权限？',
      message: '发送图片/拍照需要相机权限，文件选择使用系统选择器无需额外权限。'
          '点击"去授权"后允许即可。',
    );
    if (!go) return false;

    // 相机：拍照必需。
    await Permission.camera.request();

    // 旧机型（Android < 13）文件访问需存储权限；Android 13+ 走 picker 无需。
    if (await Permission.photos.status.then((s) => !s.isGranted)) {
      await Permission.storage.request();
    }

    // 通知（收到新消息提示）。
    await Permission.notification.request();

    return true;
  }

  /// 首次进入通话页时引导：请求麦克风（通话必需）。
  static Future<bool> ensureCallPermissions(BuildContext context) async {
    final go = await _showGuide(
      context,
      title: '开启麦克风权限？',
      message: '语音通话需要麦克风权限，点击"去授权"后允许即可。',
    );
    if (!go) return false;

    await Permission.microphone.request();
    return await Permission.microphone.isGranted;
  }

  static Future<bool> _showGuide(
    BuildContext context, {
    required String title,
    required String message,
  }) async {
    if (!context.mounted) return false;
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('暂不'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('去授权'),
          ),
        ],
      ),
    );
    return result ?? false;
  }
}
