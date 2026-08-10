/// APK 安装:通过原生 MethodChannel 调用系统安装器(ACTION_VIEW + FileProvider)。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class ApkInstaller {
  static const MethodChannel _channel = MethodChannel('myphone/install');

  /// 触发系统安装器安装指定 APK 文件。
  ///
  /// [path] 为本地 APK 绝对路径(由 OtaService.downloadApk 下载到应用文档目录)。
  /// 返回是否成功启动安装器。
  static Future<bool> installApk(String path) async {
    try {
      final result = await _channel.invokeMethod<bool>('installApk', {
        'path': path,
      });
      return result ?? false;
    } on PlatformException catch (e) {
      debugPrint('[APK-INSTALL] failed: ${e.message}');
      return false;
    }
  }
}
