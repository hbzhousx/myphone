/// 统一权限申请：登录/进入主页时一次性请求全部运行权限。
///
/// Android 6+ 需运行时动态授权。集中在此申请，避免散落在各页面
/// （发图/拍照/文件/拨号时才弹）造成「一会提示权限不够」的体验割裂。
library;

import 'package:permission_handler/permission_handler.dart';

class PermissionService {
  /// 启动时一次性申请：相机（拍照）、存储/媒体（图库、文件）、麦克风（通话）。
  /// 通知权限 Android 13+ 单独请求。
  /// 返回是否有权限被拒绝（供 UI 提示）。
  static Future<bool> requestAllOnStartup() async {
    // 麦克风：通话必需。
    await Permission.microphone.request();

    // 相机 + 存储：聊天附件（拍照/图库/文件）。Android 13+ 用 photos/videos，
    // 旧版用 storage。分开请求更稳妥（用户可只授权需要的）。
    await Permission.camera.request();
    await Permission.storage.request();
    await Permission.photos.request();

    // 通知：Android 13+ 推送消息。
    await Permission.notification.request();

    // 返回是否仍有关键权限被拒（供设置页引导）。
    final mic = await Permission.microphone.isGranted;
    final cam = await Permission.camera.isGranted;
    final storage = await Permission.storage.isGranted ||
        await Permission.photos.isGranted;
    return !(mic && cam && storage);
  }
}
