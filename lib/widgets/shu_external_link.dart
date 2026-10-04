import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'shu_surfaces.dart';

/// 打开一个外部链接。
///
/// 一律走系统浏览器（`externalApplication`）：这些链接落在 shu.edu.cn 或
/// GitHub 上，登录与跨站跳转交给浏览器处理更可靠 —— 应用内打开要么开一个
/// WebView（那就要自己维护一套 cookie 与返回栈），要么抢走用户的浏览器会话。
///
/// 打不开时说一句，而不是静默失败：点一下什么都没发生是最难排查的那种。
Future<void> openShuExternalUrl(BuildContext context, Uri url) async {
  var opened = false;
  try {
    opened = await launchUrl(url, mode: LaunchMode.externalApplication);
  } on Object {
    opened = false;
  }
  if (!opened && context.mounted) showShuSnack(context, '无法打开链接');
}
