import 'package:flutter/material.dart';

import '../../app/shuyo_text_styles.dart';
import '../../app/theme.dart';
import '../../widgets/shu_app_bar.dart';

/// 关于页「隐私与声明 → 权限说明」进来的地方。
///
/// 版式照 `ShuYo` 的 `_PermissionInfoPage`：页首一句总说明，下面一行一项权限
/// （图标 + 名称 + 一句用途），页尾一句收尾。
///
/// 条目按 ShuVPN 在 `AndroidManifest.xml` 里真实声明的权限重写。VPN 服务那
/// 一项不在清单里 —— 它来自 `VpnService.prepare()` 的弹窗（见
/// `welcome_page.dart` 的 `_ShuPermission.vpn`），但同样是用户会看到的一项授权。
class PermissionInfoPage extends StatelessWidget {
  const PermissionInfoPage({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return Scaffold(
      appBar: ShuAppBar(
        title: '权限说明',
        onBack: () => Navigator.of(context).pop(),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        children: [
          Text(
            '为了实现对应功能，ShuVPN 可能会在你使用功能时申请以下权限。'
            '具体项目会因系统版本而异。',
            style: ShuYoTextStyles.bodyCompact(color: colors.textSecondary),
          ),
          const SizedBox(height: 18),
          const _PermissionItem(
            icon: Icons.vpn_lock_outlined,
            title: 'VPN 服务',
            body: '由系统授权后建立隧道。拒绝这一项就无法连接。',
          ),
          const _PermissionItem(
            icon: Icons.notifications_outlined,
            title: '通知',
            body: '隧道运行时在通知栏显示状态，并提供断开入口。',
          ),
          const _PermissionItem(
            icon: Icons.language,
            title: '网络访问',
            body: '用于连接网关、校验校园账户与建立隧道。',
          ),
          const SizedBox(height: 8),
          Text(
            '你可以在系统设置中随时查看或更改已授予的权限。'
            '拒绝某项权限只会影响对应功能。',
            style: ShuYoTextStyles.meta(color: colors.textMuted, height: 1.5),
          ),
        ],
      ),
    );
  }
}

/// 权限列表里的一行。
class _PermissionItem extends StatelessWidget {
  const _PermissionItem({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon),
      title: Text(title),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(body),
      ),
    );
  }
}
