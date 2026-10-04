import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app/app_info.dart';
import '../core/update/shu_update_info.dart';
import 'shu_surfaces.dart';

/// 「发现新版本」对话框，版式逐项照 `ShuYo` 的 `showClientUpdatePrompt`。
///
/// 返回用户是否选了「更新」。没有可下载地址时那个按钮不出现，于是只剩
/// 「知道了」，返回值恒为 false。
///
/// `barrierDismissible` 为 false：这不是一次可以顺手点掉的打扰，它要么被
/// 明确接受，要么被明确拒绝，两种回答都会落到调用方手里。
Future<bool> showShuUpdatePrompt(
  BuildContext context, {
  required ShuUpdateInfo update,
}) async {
  final openDownload = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => AlertDialog(
      title: const Text('发现新版本'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('当前版本：${ShuAppInfo.version}'),
            const SizedBox(height: 8),
            Text('最新版本：${update.latestVersion}'),
          ],
        ),
      ),
      actions: [
        if (update.hasDownloadUrl)
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('更新'),
          ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('知道了'),
        ),
      ],
    ),
  );
  return openDownload ?? false;
}

/// 打开更新地址，返回是否成功；失败时用 snack 说明原因。
///
/// 一律走系统浏览器（`externalApplication`）：APK 直链最终落到 GitHub 的
/// 下载重定向，交给浏览器比在应用内接一个下载器省事，也少一份权限。
Future<bool> openShuUpdateUrl(BuildContext context, String url) async {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || !uri.hasScheme) {
    showShuSnack(context, '下载链接无效');
    return false;
  }
  var opened = false;
  try {
    opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
  } on Object {
    opened = false;
  }
  if (!opened && context.mounted) showShuSnack(context, '无法打开下载链接');
  return opened;
}
