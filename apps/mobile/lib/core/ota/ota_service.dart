/// OTA 远程升级服务:检查服务器新版本、下载 APK。
///
/// 检查:GET /v1/ota/check 返回最新版本元数据;与本地(package_info)比较。
/// 下载:GET /v1/ota/download 流式写入本地文件。
library;

import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../network/api_client.dart';

/// 服务器返回的升级信息。
class UpdateInfo {
  final String version;
  final int build;
  final String url;
  final String notes;
  final bool mandatory;

  const UpdateInfo({
    required this.version,
    required this.build,
    required this.url,
    required this.notes,
    required this.mandatory,
  });

  factory UpdateInfo.fromJson(Map<String, dynamic> json) => UpdateInfo(
        version: json['version'] as String? ?? '',
        build: json['build'] as int? ?? 0,
        url: json['url'] as String? ?? '/v1/ota/download',
        notes: json['notes'] as String? ?? '',
        mandatory: json['mandatory'] as bool? ?? false,
      );
}

class OtaService {
  final ApiClient _api;

  OtaService({ApiClient? api}) : _api = api ?? ApiClient();

  /// 检查是否有新版本。返回服务器版本信息;本地已最新则返回 null。
  Future<UpdateInfo?> checkForUpdate() async {
    final info = UpdateInfo.fromJson(await _api.checkForUpdate());
    final local = await PackageInfo.fromPlatform();
    final localBuild = int.tryParse(local.buildNumber) ?? 0;
    // 服务器 build > 本地 build 即视为有新版本。
    if (info.build > localBuild) {
      return info;
    }
    return null;
  }

  /// 下载 APK 到应用 support 目录,返回本地文件路径。
  /// 用 getApplicationSupportDirectory()(Android 对应 /data/user/0/<pkg>/files)
  /// 而非 getApplicationDocumentsDirectory()(app_flutter/),因为 FileProvider 的
  /// file_paths.xml 声明的是 <files-path>,只有 files/ 目录才能被系统安装器读取。
  /// [onProgress] 下载进度回调(received/total)。
  Future<String> downloadApk({void Function(int received, int total)? onProgress}) async {
    final dir = await getApplicationSupportDirectory();
    final dest = '${dir.path}/myphone-latest.apk';
    await _api.downloadApk(dest, onProgress: onProgress);
    return dest;
  }

  void dispose() => _api.dispose();
}
