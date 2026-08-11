import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../../../app/auth_guard.dart';
import '../../../core/network/service_bridge.dart';
import '../../../core/ota/apk_installer.dart';
import '../../../core/ota/ota_service.dart';
import '../../auth/biometric_auth.dart';
import '../settings_state.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _ota = OtaService();
  String _versionLabel = '…';
  bool _checkingUpdate = false;
  bool _biometricEnabled = false;
  bool _biometricLoading = true;

  @override
  void initState() {
    super.initState();
    _loadVersion();
    _loadBiometricState();
  }

  Future<void> _loadBiometricState() async {
    final enabled = await AuthGuard.isBiometricEnabled();
    if (mounted) {
      setState(() {
        _biometricEnabled = enabled;
        _biometricLoading = false;
      });
    }
  }

  Future<void> _toggleBiometric(bool enable) async {
    if (enable) {
      // 开启前先确认设备支持 + 通过一次指纹验证。
      final availability = await BiometricAuth.checkAvailability();
      if (!availability.isAvailable || !availability.isEnrolled) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('Biometric not available or not enrolled')));
        }
        return;
      }
      final result = await BiometricAuth.authenticate(
          reason: 'Enable fingerprint unlock');
      if (result != BiometricResult.success) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('Fingerprint verification failed')));
        }
        return;
      }
      final savedPhone = await AuthGuard.getSavedPhone();
      await AuthGuard.setBiometricEnabled(true, phone: savedPhone);
    } else {
      await AuthGuard.setBiometricEnabled(false);
    }
    if (mounted) setState(() => _biometricEnabled = enable);
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) {
        setState(() => _versionLabel = '${info.version} (build ${info.buildNumber})');
      }
    } catch (_) {}
  }

  /// 打开系统"电池优化/忽略电池优化"设置页（各 ROM 路径见白名单引导文案）。
  Future<void> _openBatteryOptimizationSettings() async {
    if (!Platform.isAndroid) return;
    try {
      await const MethodChannel('myphone/system')
          .invokeMethod('openBatterySettings');
    } catch (_) {}
  }

  /// 检测是否已在电池白名单 + 获取厂商，返回可展示的引导文案。
  Future<String> _batteryHint() async {
    if (!Platform.isAndroid) return '';
    try {
      final status = await const MethodChannel('myphone/system')
          .invokeMethod('getBatteryStatus') as Map;
      final ignoring = status['ignoringOptimization'] == true;
      if (ignoring) return '已加入电池白名单，息屏可保持来电在线 ✅';
      final m = (status['manufacturer'] as String? ?? '').toLowerCase();
      if (m.contains('huawei') || m.contains('honor')) {
        return '华为/荣耀：请在"应用启动管理"中允许自启动+后台运行，否则息屏会被冻结';
      } else if (m.contains('vivo') || m.contains('iqoo')) {
        return 'vivo/iQOO：请在"自启动管理"中允许 MyPhone 自启动，否则息屏会被冻结';
      } else if (m.contains('xiaomi') || m.contains('redmi') || m.contains('poco')) {
        return '小米/Redmi/POCO：请在"自启动管理"中允许自启动，否则息屏会被冻结';
      } else if (m.contains('oppo') || m.contains('realme') || m.contains('oneplus')) {
        return 'OPPO/realme/一加：请在"自启动"中允许后台运行，否则息屏会被冻结';
      } else if (m.contains('samsung')) {
        return '三星：请在"电池-后台使用限制"中设为不受限制';
      } else if (m.contains('meizu')) {
        return '魅族：请在"应用管理-自启动"中允许自启动';
      } else if (m.contains('zte') || m.contains('nubia')) {
        return '中兴/Nubia：请在"电池"中设为不优化';
      } else if (m.contains('lenovo') || m.contains('motorola')) {
        return '联想/Moto：请在"电池优化"中选择不优化';
      } else {
        return '点击加入电池白名单，防止息屏时被系统冻结';
      }
    } catch (_) {
      return '点击加入电池白名单，防止息屏时被系统冻结';
    }
  }

  Future<void> _checkUpdate() async {
    if (_checkingUpdate) return;
    setState(() => _checkingUpdate = true);
    try {
      final update = await _ota.checkForUpdate();
      if (!mounted) return;
      if (update == null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Already up to date')));
        return;
      }
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Update available v${update.version}'),
          content: Text(update.notes.isEmpty
              ? 'Download and install?'
              : '${update.notes}\n\nDownload and install?'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Download')),
          ],
        ),
      );
      if (confirm == true && mounted) {
        // 下载进度对话框:用 ValueNotifier 持有进度,ValueListenableBuilder 自动刷新。
        final progress = ValueNotifier<double?>(null);
        // ignore: use_build_context_synchronously
        showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            title: const Text('Downloading update...'),
            content: Row(
              children: [
                Expanded(
                  child: ValueListenableBuilder<double?>(
                    valueListenable: progress,
                    builder: (context, v, child) =>
                        LinearProgressIndicator(value: v),
                  ),
                ),
                const SizedBox(width: 12),
                ValueListenableBuilder<double?>(
                  valueListenable: progress,
                  builder: (context, v, child) => Text(
                    v == null ? '' : '${(v * 100).toStringAsFixed(0)}%',
                  ),
                ),
              ],
            ),
          ),
        );
        final path = await _ota.downloadApk(
          onProgress: (r, t) {
            progress.value = t > 0 ? r / t : null;
          },
        );
        if (mounted) Navigator.of(context, rootNavigator: true).pop();
        if (!mounted) return;
        final installed = await ApkInstaller.installApk(path);
        if (!installed && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Failed to open installer')));
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Update check failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _checkingUpdate = false);
    }
  }

  @override
  void dispose() {
    _ota.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          const _SectionHeader(title: 'Account'),
          FutureBuilder<String?>(
            future: AuthGuard.getUserId(),
            builder: (context, snapshot) {
              return ListTile(
                leading: const CircleAvatar(child: Icon(Icons.person)),
                title: const Text('User ID'),
                subtitle: Text(snapshot.data ?? 'Not signed in'),
              );
            },
          ),
          const Divider(),

          const _SectionHeader(title: 'Preferences'),
          SwitchListTile(
            title: const Text('Call Notifications'),
            subtitle: const Text('Show incoming call alerts'),
            value: settings.notificationsEnabled,
            onChanged: (_) =>
                ref.read(settingsProvider.notifier).toggleNotifications(),
            secondary: const Icon(Icons.notifications),
          ),
          SwitchListTile(
            title: const Text('Fingerprint Unlock'),
            subtitle: const Text('Sign in with your fingerprint'),
            value: _biometricEnabled,
            onChanged: _biometricLoading ? null : _toggleBiometric,
            secondary: const Icon(Icons.fingerprint),
          ),
          if (Platform.isAndroid) ...[
            SwitchListTile(
              title: const Text('常驻后台（保持在线）'),
              subtitle: const Text('退出 app 后仍保持登录，来电全屏唤醒'),
              value: settings.residentEnabled,
              onChanged: (v) async {
                await ref
                    .read(settingsProvider.notifier)
                    .toggleResident();
                await ResidentService.applyEnabled(v);
              },
              secondary: const Icon(Icons.power_settings_new),
            ),
            ListTile(
              leading: const Icon(Icons.battery_saver),
              title: const Text('加入电池白名单'),
              subtitle: FutureBuilder<String>(
                future: _batteryHint(),
                builder: (context, snapshot) => Text(
                  snapshot.data ?? '检测中...',
                  style: TextStyle(
                    fontSize: 12,
                    color: (snapshot.data?.contains('✅') ?? false)
                        ? Colors.green
                        : Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              onTap: _openBatteryOptimizationSettings,
            ),
          ],
          const Divider(),

          const _SectionHeader(title: 'Update'),
          ListTile(
            leading: const Icon(Icons.system_update),
            title: const Text('Check for updates'),
            subtitle: const Text('Download and install the latest version'),
            trailing: _checkingUpdate
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : null,
            onTap: _checkingUpdate ? null : _checkUpdate,
          ),
          const Divider(),

          const _SectionHeader(title: 'About'),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('Version'),
            subtitle: Text(_versionLabel),
          ),
          const ListTile(
            leading: Icon(Icons.security),
            title: Text('Encryption'),
            subtitle: Text('E2E encrypted calls with X25519 + AES-256-GCM'),
          ),
          const Divider(),

          Padding(
            padding: const EdgeInsets.all(16),
            child: ElevatedButton.icon(
              onPressed: () async {
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Sign Out'),
                    content:
                        const Text('Are you sure you want to sign out?'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('Cancel')),
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text('Sign Out')),
                    ],
                  ),
                );
                if (confirm == true && context.mounted) {
                  // v0.4: 先停常驻服务（断 WS 离线），再清 token。
                  await ResidentService.logout();
                  await AuthGuard.clearToken();
                  context.go('/login');
                }
              },
              icon: const Icon(Icons.logout),
              label: const Text('Sign Out'),
              style: ElevatedButton.styleFrom(
                backgroundColor: theme.colorScheme.error,
                foregroundColor: theme.colorScheme.onError,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: Theme.of(context).colorScheme.primary,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}
