/// 联系人头像：有 avatarPath 显示图片，无则首字母 CircleAvatar。
/// 复用于联系人列表/详情/会话列表/聊天AppBar/通话界面。
library;

import 'dart:io';

import 'package:flutter/material.dart';

class ContactAvatar extends StatelessWidget {
  final String? avatarPath;
  final String initials;
  final double radius;

  const ContactAvatar({
    super.key,
    required this.avatarPath,
    required this.initials,
    this.radius = 20,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final path = avatarPath;
    final canShowImage =
        path != null && path.isNotEmpty && File(path).existsSync();
    if (canShowImage) {
      return CircleAvatar(
        radius: radius,
        backgroundImage: FileImage(File(path)),
        onBackgroundImageError: (_, __) {},
      );
    }
    // 无头像：首字母占位。
    return CircleAvatar(
      radius: radius,
      backgroundColor: scheme.primaryContainer,
      child: Text(
        initials.isEmpty ? '?' : initials,
        style: TextStyle(color: scheme.onPrimaryContainer),
      ),
    );
  }
}
