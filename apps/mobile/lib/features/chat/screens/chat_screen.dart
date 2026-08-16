/// 单会话聊天页：消息列表 + 输入栏（emoji/附件/文本）+ 阅后即焚选择。
library;

import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';

import '../../../core/permission/permission_service.dart';
import '../../../core/storage/database.dart';
import '../chat_message_repository.dart';
import '../chat_session_controller.dart' show kChatDiag;
import '../chat_state.dart';
import '../widgets/message_bubble.dart';
import 'location_picker_screen.dart';

/// 阅后即焚可选项：秒数 → 显示文案。
/// 最小从 1 小时起（短暂选项会让消息在几秒/几分钟内消失，用户以为消息丢失）。
/// 默认「关」，选择非「关」项需勾选确认。
const List<(int, String)> _disappearOptions = [
  (0, '关'),
  (3600, '1小时'),
  (86400, '24小时'),
  (604800, '1周'),
  (2592000, '1个月'),
];

class ChatScreen extends ConsumerStatefulWidget {
  final String contactId;
  const ChatScreen({super.key, required this.contactId});
  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

/// 附件来源。
enum _AttachSource { gallery, camera, file, location }

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _inputController = TextEditingController();
  List<Map<String, dynamic>> _messages = [];
  bool _loading = true;
  String _displayName = '';
  int _disappearSeconds = 0;
  Timer? _pollTimer;

  /// 会话消息仓库（懒建）：数据访问 + 附件路径补全 + 诊断上报。
  ChatMessageRepository? _loader;

  String get _conversationId => 'conv-${widget.contactId}';

  @override
  void initState() {
    super.initState();
    ref.read(chatStateProvider.notifier).setActiveConversation(_conversationId);
    // 首次进入聊天页引导授权（相机/存储/通知），避免发图时临时弹窗。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      PermissionService.ensureChatPermissions(context);
    });
    _loadContact();
    _loadMessages();
    // 周期轮询：捕捉入站新消息/回执/阅后即焚（信令落库后在此刷新）。
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _loadMessages();
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _inputController.dispose();
    ref.read(chatStateProvider.notifier).setActiveConversation(null);
    super.dispose();
  }

  /// 联系人 id → 展示名（联系人表匹配失败则回退为原始 id）。
  Future<void> _loadContact() async {
    String name = widget.contactId;
    try {
      final row = await DatabaseManager.instance.getContact(widget.contactId);
      if (row != null) {
        final n = row['display_name'] as String?;
        if (n != null && n.isNotEmpty) name = n;
      }
    } catch (_) {}
    if (mounted) setState(() => _displayName = name);
  }

  /// 懒建会话消息仓库：首次调用等 controllerFor（内部等 chat ready）后构造，
  /// 之后轮询直接复用。数据查询/附件补全/诊断都收敛到仓库，widget 只编排。
  Future<ChatMessageRepository> _ensureLoader() async {
    if (_loader != null) return _loader!;
    final controller = await ref.read(chatStateProvider.notifier).controllerFor(
          remoteUserId: widget.contactId,
          conversationId: _conversationId,
        );
    _loader = ChatMessageRepository(
      db: DatabaseManager.instance,
      conversationId: _conversationId,
      onDiag: kChatDiag ? controller.reportDiagnostic : null,
    );
    return _loader!;
  }

  Future<void> _loadMessages() async {
    try {
      final rows = await _ensureLoader().then((l) => l.load());
      if (!mounted) return;
      setState(() {
        _messages = rows;
        _loading = false;
      });
      _maybeReadIncoming(rows);
      _syncDisappearSetting();
    } catch (e, st) {
      debugPrint('[CHAT] load messages failed: $e');
      // 诊断：上报 _loadMessages 异常（fire-and-forget，走仓库 onDiag）。
      try {
        _loader?.onDiag?.call('ui:loadError',
            {'conv': _conversationId, 'err': '$e', 'stack': '$st'});
      } catch (_) {}
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 新入站消息显示时自动回已读（markRead 会发 read 回执给对端）。
  Future<void> _maybeReadIncoming(List<Map<String, dynamic>> rows) async {
    final controller = await ref.read(chatStateProvider.notifier).controllerFor(
          remoteUserId: widget.contactId,
          conversationId: _conversationId,
        );
    for (final msg in rows) {
      final direction = msg['direction'] as String?;
      final status = msg['status'] as String?;
      if (direction == 'incoming' && status != null && status != 'read') {
        await controller.markRead(msg['id'] as String);
      }
    }
  }

  /// 把会话当前的阅后即焚设置同步到 AppBar 选择器。
  Future<void> _syncDisappearSetting() async {
    try {
      final conv = await DatabaseManager.instance
          .getConversation(_conversationId);
      final seconds = (conv?['disappearing_seconds'] as num?)?.toInt() ?? 0;
      if (seconds != _disappearSeconds && mounted) {
        setState(() => _disappearSeconds = seconds);
      }
    } catch (_) {}
  }

  Future<void> _sendText() async {
    final body = _inputController.text.trim();
    if (body.isEmpty) return;
    _inputController.clear();
    try {
      final controller = await ref.read(chatStateProvider.notifier).controllerFor(
            remoteUserId: widget.contactId,
            conversationId: _conversationId,
          );
      final result = await controller.sendText(body,
          expiresInSeconds: _disappearSeconds);
      if (result != null && result.containsKey('error')) {
        // 会话建立失败（未登录/离线）时给出提示，避免静默丢消息。
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('发送失败：${result['error']}')),
          );
        }
      }
    } catch (e) {
      debugPrint('[CHAT] send text failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('发送失败：$e')),
        );
      }
    }
    await _loadMessages();
  }

  /// 常用 emoji 快速选择（v0.5 简化：不引入 emoji_picker 依赖）。
  static const List<String> _quickEmojis = [
    '😀', '😂', '😍', '😎', '😭', '😡', '👍', '👎',
    '🙏', '👏', '💪', '🎉', '❤️', '💔', '🔥', '✅',
    '❌', '❓', '❗', '💤', '☕', '🍺', '🌹', '⭐',
  ];

  Future<void> _insertEmoji() async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final e in _quickEmojis)
                InkWell(
                  onTap: () => Navigator.pop(ctx, e),
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Text(e, style: const TextStyle(fontSize: 26)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (selected != null && mounted) {
      _inputController.text += selected;
    }
  }

  /// 附件来源选择：图库 / 相机 / 文件。
  Future<void> _pickAndSendFile() async {
    if (!mounted) return;
    final source = await showModalBottomSheet<_AttachSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('从图库选择图片'),
              onTap: () => Navigator.pop(ctx, _AttachSource.gallery),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('拍照'),
              onTap: () => Navigator.pop(ctx, _AttachSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.insert_drive_file_outlined),
              title: const Text('发送文件'),
              onTap: () => Navigator.pop(ctx, _AttachSource.file),
            ),
            ListTile(
              leading: const Icon(Icons.place_outlined),
              title: const Text('位置'),
              onTap: () => Navigator.pop(ctx, _AttachSource.location),
            ),
          ],
        ),
      ),
    );
    if (source == null || !mounted) return;

    switch (source) {
      case _AttachSource.gallery:
        await _sendImage(ImageSource.gallery);
      case _AttachSource.camera:
        await _sendImage(ImageSource.camera);
      case _AttachSource.file:
        await _sendFilePicker();
      case _AttachSource.location:
        await _sendLocation();
    }
  }

  /// 选图片/拍照发送。
  Future<void> _sendImage(ImageSource source) async {
    try {
      // 图库走系统 Photo Picker（无需存储权限；vivo 的"仅可发送选择的内容"是
      // Android 正常的 partial access，不是错误）。仅拍照需要相机权限。
      if (source == ImageSource.camera &&
          !await Permission.camera.isGranted) {
        _showSendError('需要相机权限，请在系统设置中允许');
        return;
      }
      final picked = await ImagePicker().pickImage(
        source: source,
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 85,
      );
      if (picked == null || !mounted) return;
      final file = File(picked.path);
      final name = picked.name.isNotEmpty ? picked.name : p.basename(picked.path);
      final mime = lookupMimeType(picked.path) ?? 'image/jpeg';

      // 发送前确认：预览图片 + 发送/取消。
      final confirmed = await _confirmImageSend(file, name);
      if (!confirmed || !mounted) return;

      final controller = await ref
          .read(chatStateProvider.notifier)
          .controllerFor(
            remoteUserId: widget.contactId,
            conversationId: _conversationId,
          );
      final result = await controller.sendFile(
        filePath: file.path,
        kind: 'image',
        fileName: name,
        mimeType: mime,
        expiresInSeconds: _disappearSeconds,
      );
      if (result != null && result.containsKey('error')) {
        _showSendError(result['error'].toString());
      }
      await _loadMessages();
    } catch (e) {
      debugPrint('[CHAT] pick image failed: $e');
      _showSendError('发送图片失败：$e');
    }
  }

  /// 图片发送确认对话框：预览缩略图 + 文件名，确认才发送。
  Future<bool> _confirmImageSend(File file, String name) async {
    if (!mounted) return false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('发送图片？'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.file(
                file,
                height: 200,
                width: 200,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) =>
                    const SizedBox(height: 100, child: Icon(Icons.image, size: 48)),
              ),
            ),
            const SizedBox(height: 8),
            Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('发送'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  /// 文件发送确认对话框：文件名 + 大小，确认才发送。
  Future<bool> _confirmFileSend(String name, int sizeBytes) async {
    if (!mounted) return false;
    final sizeText = sizeBytes > 1024 * 1024
        ? '${(sizeBytes / 1024 / 1024).toStringAsFixed(1)} MB'
        : '${(sizeBytes / 1024).toStringAsFixed(0)} KB';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('发送文件？'),
        content: Text('$name\n($sizeText)', maxLines: 3, overflow: TextOverflow.ellipsis),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('发送'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  /// 选任意文件发送。
  Future<void> _sendFilePicker() async {
    try {
      // file_picker 走系统 SAF（Storage Access Framework），无需存储权限。
      final picked = await FilePicker.platform.pickFiles();
      if (picked == null || picked.files.isEmpty || !mounted) return;
      final f = picked.files.first;
      final path = f.path;
      if (path == null) {
        _showSendError('无法读取所选文件');
        return;
      }
      final name = f.name.isNotEmpty ? f.name : p.basename(path);
      final mime = lookupMimeType(name) ?? 'application/octet-stream';

      // 发送前确认：文件名 + 大小 + 发送/取消。
      final confirmed = await _confirmFileSend(name, f.size);
      if (!confirmed || !mounted) return;

      final controller = await ref
          .read(chatStateProvider.notifier)
          .controllerFor(
            remoteUserId: widget.contactId,
            conversationId: _conversationId,
          );
      final result = await controller.sendFile(
        filePath: path,
        kind: mime.startsWith('video/') ? 'video' : 'file',
        fileName: name,
        mimeType: mime,
        expiresInSeconds: _disappearSeconds,
      );
      if (result != null && result.containsKey('error')) {
        _showSendError(result['error'].toString());
      }
      await _loadMessages();
    } catch (e) {
      debugPrint('[CHAT] pick file failed: $e');
      _showSendError('选择文件失败：$e');
    }
  }

  /// 地图选点位置发送：权限 → 打开地图选点页（flutter_map+高德瓦片，接受网格误差）
  /// → 用户拖动选点 → 发送坐标（GCJ-02，接收端高德/百度 URI 用）。
  Future<void> _sendLocation() async {
    try {
      // 定位权限。
      final perm = await Geolocator.checkPermission();
      _diagLoc('ui:loc-perm', {'perm': perm.name});
      if (perm == LocationPermission.denied) {
        final granted = await Geolocator.requestPermission();
        _diagLoc('ui:loc-perm-request', {'granted': granted.name});
        if (granted == LocationPermission.denied ||
            granted == LocationPermission.deniedForever) {
          _showSendError('需要定位权限才能发送位置');
          return;
        }
      }
      if (!mounted) return;
      // 打开地图选点页（用户拖动选点；接受高德瓦片网格误差）。
      final picked = await showLocationPicker(context);
      _diagLoc('ui:loc-picked', {'picked': picked != null});
      if (picked == null || !mounted) return;
      final controller = await ref
          .read(chatStateProvider.notifier)
          .controllerFor(
            remoteUserId: widget.contactId,
            conversationId: _conversationId,
          );
      final result = await controller.sendLocation(
        latitude: picked.latitude,
        longitude: picked.longitude,
        expiresInSeconds: _disappearSeconds,
      );
      _diagLoc('ui:loc-sent', {'result': result?.toString() ?? 'null'});
      if (result != null && result.containsKey('error')) {
        _showSendError(result['error'].toString());
      }
      await _loadMessages();
    } catch (e) {
      debugPrint('[CHAT] send location failed: $e');
      _diagLoc('ui:loc-error', {'err': '$e'});
      _showSendError('获取位置失败：$e');
    }
  }

  /// 位置功能诊断（fire-and-forget 上报服务器）。
  void _diagLoc(String step, Map<String, dynamic> data) {
    try {
      _loader?.onDiag?.call(step, data);
    } catch (_) {}
  }

  void _showSendError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('发送失败：$message')),
    );
  }

  /// AppBar "..." → 清空本会话所有聊天记录（确认后本地清空）。
  Future<void> _clearAllMessages() async {
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空所有聊天记录？'),
        content: const Text('将删除本会话的全部消息（仅从本机移除，对方仍可见）。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await DatabaseManager.instance
          .clearConversationMessages(_conversationId);
      await _loadMessages();
    } catch (e) {
      debugPrint('[CHAT] clear messages failed: $e');
    }
  }

  /// 长按消息 → 确认删除单条（本地删除）。
  Future<void> _deleteMessage(String messageId) async {
    if (messageId.isEmpty || !mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这条消息？'),
        content: const Text('删除后仅从本机移除，对方仍可见。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final controller = await ref.read(chatStateProvider.notifier).controllerFor(
            remoteUserId: widget.contactId,
            conversationId: _conversationId,
          );
      await controller.deleteMessage(messageId);
      await _loadMessages();
    } catch (e) {
      debugPrint('[CHAT] delete message failed: $e');
    }
  }

  /// 打开已接收的文件/图片（本地解密后路径）。
  /// 图片/视频 → 应用内预览；文件 → 原生系统打开（FileProvider + ACTION_VIEW）。
  Future<void> _openAttachment(String transferId) async {
    try {
      final attach = await DatabaseManager.instance.getAttachment(transferId);
      if (attach == null) return;
      // ★规范化路径：FileProvider 的 root-path 用 canonical path 匹配，而
      //   /data/data/<pkg> 与 /data/user/0/<pkg> 是符号链接。若传未规范化的
      //   /data/data/...，FileProvider 找不到 root → "Failed to find configured root"
      //   → 打不开。resolveSymbolicLinksSync 消除符号链接差异，两边一致。
      final rawPath = attach['local_plain_path'] as String?;
      late String path;
      if (rawPath == null) {
        _showSendError('文件尚未到达');
        return;
      }
      try {
        path = File(rawPath).resolveSymbolicLinksSync();
      } catch (_) {
        path = rawPath;
      }
      // 诊断：点击附件时上报 path+exists+size（定位"文件收到但无法预览/打开"）。
      final f = File(path);
      final exists = f.existsSync();
      try {
        _loader?.onDiag?.call('ui:open-attach', {
          'tid': transferId,
          'path': path,
          'exists': exists,
          'size': exists ? f.lengthSync() : -1,
          'kind': attach['kind'],
          'enc': attach['local_enc_path'],
        });
      } catch (_) {}
      if (!File(path).existsSync()) {
        _showSendError('文件尚未到达');
        return;
      }
      if (!mounted) return;
      final kind = attach['kind'] as String? ?? 'file';

      if (kind == 'image' || kind == 'video') {
        // 图片/视频预览大图。
        await showDialog<void>(
          context: context,
          builder: (ctx) => Dialog(
            child: InteractiveViewer(
              child: Image.file(
                File(path),
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => const SizedBox(
                height: 120,
                child: Center(child: Text('无法预览')),
              ),
            ),
          ),
        ),
        );
      } else {
        // 文件 → 原生系统打开（MainActivity 用 FileProvider 生成 content:// 后
        // ACTION_VIEW，对齐 Signal 的 Intent.ACTION_VIEW + PartProvider）。
        final mime = attach['mime_type'] as String? ?? 'application/octet-stream';
        // 诊断：打开开始（若转圈且此步已报但 ui:open-native 未报 → 卡在 MethodChannel）。
        try {
          _loader?.onDiag?.call('ui:open-start', {'tid': transferId, 'mime': mime, 'path': path});
        } catch (_) {}
        final res = await _openFileNative(path, mime);
        final ok = res['ok'] as int? ?? 0;
        final err = res['err'] as String?;
        // 诊断：原生打开结果（定位 PDF 打不开——FileProvider false vs 无查看器）。
        try {
          _loader?.onDiag?.call('ui:open-native', {
            'tid': transferId,
            'path': path,
            'mime': mime,
            'ok': ok,
            if (err != null) 'err': err,
          });
        } catch (_) {}
        if (ok == 2) {
          // 无应用能处理该类型 → 微信式引导：提示用户安装可打开的应用。
          if (mounted) _showSendError('未安装可打开此文件的应用');
        } else if (ok != 1 && mounted) {
          _showSendError('无法用其他应用打开该文件');
        }
      }
    } catch (e) {
      debugPrint('[CHAT] open attachment failed: $e');
    }
  }

  /// 经 MethodChannel 调原生打开文件（FileProvider + ACTION_VIEW + resolveActivity）。
  /// 返回 Map：{'ok': 1成功/0失败/2无应用, 'err': 异常详情}。
  static const _openChannel = MethodChannel('myphone/open');
  Future<Map<String, dynamic>> _openFileNative(String path, String mime) async {
    try {
      final r = await _openChannel
          .invokeMethod<Map<dynamic, dynamic>>('openFile', {'path': path, 'mime': mime});
      return Map<String, dynamic>.from(r ?? const {});
    } catch (e) {
      debugPrint('[CHAT] native open failed: $e');
      return {'ok': 0, 'err': '$e'};
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(_displayName.isEmpty ? widget.contactId : _displayName),
        actions: [
          // 阅后即焚设置：变更后发信令给对端同步会话默认值。
          PopupMenuButton<int>(
            initialValue: _disappearSeconds,
            onSelected: (seconds) async {
              // 选非「关」项需勾选确认（说明消息会定时删除），避免误触后消息消失。
              if (seconds > 0) {
                final label = _disappearOptions
                    .firstWhere((o) => o.$1 == seconds)
                    .$2;
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('开启阅后即焚？'),
                    content: Text('开启后，本会话的消息将在 $label 后自动删除（两端）。确定开启？'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('取消'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('开启'),
                      ),
                    ],
                  ),
                );
                if (confirmed != true || !mounted) return;
              }
              setState(() => _disappearSeconds = seconds);
              final controller = await ref
                  .read(chatStateProvider.notifier)
                  .controllerFor(
                    remoteUserId: widget.contactId,
                    conversationId: _conversationId,
                  );
              controller.sendDisappearingSetting(seconds);
            },
            itemBuilder: (context) => [
              for (final (seconds, label) in _disappearOptions)
                PopupMenuItem<int>(value: seconds, child: Text(label)),
            ],
            icon: const Icon(Icons.timer_outlined),
          ),
          // 更多：清空所有聊天记录。
          PopupMenuButton<String>(
            onSelected: (value) async {
              if (value == 'clear') await _clearAllMessages();
            },
            itemBuilder: (context) => const [
              PopupMenuItem<String>(
                value: 'clear',
                child: Text('清空所有聊天记录'),
              ),
            ],
            icon: const Icon(Icons.more_horiz),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _messages.isEmpty
                    ? const Center(child: Text('暂无消息，发送一条开启端到端加密聊天'))
                    : ListView.builder(
                        reverse: true,
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: _messages.length,
                        itemBuilder: (context, index) {
                          final msg = _messages[_messages.length - 1 - index];
                          final outgoing =
                              msg['direction'] == 'outgoing';
                          final kind = msg['kind'] as String? ?? 'text';
                          final transferId = msg['transfer_id'] as String?;
                          return MessageBubble(
                            text: msg['body'] as String? ?? '',
                            kind: kind,
                            isOutgoing: outgoing,
                            status: msg['status'] as String?,
                            timestamp: (msg['created_at'] as num?)?.toInt(),
                            transferId: transferId,
                            attachmentPath: msg['_attachment_path'] as String?,
                            latitude: (msg['latitude'] as num?)?.toDouble(),
                            longitude: (msg['longitude'] as num?)?.toDouble(),
                            onAttachmentTap: transferId != null
                                ? () => _openAttachment(transferId)
                                : null,
                            onLongPress: () => _deleteMessage(
                                msg['id'] as String? ?? ''),
                          );
                        },
                      ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  IconButton(
                    icon: const Icon(Icons.emoji_emotions_outlined),
                    onPressed: _insertEmoji,
                  ),
                  Expanded(
                    child: TextField(
                      controller: _inputController,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.newline,
                      decoration: InputDecoration(
                        hintText: '输入消息…',
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 10),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                        ),
                      ),
                      onSubmitted: (_) => _sendText(),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.attach_file),
                    onPressed: _pickAndSendFile,
                  ),
                  IconButton(
                    icon: Icon(Icons.send, color: scheme.primary),
                    onPressed: _sendText,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
