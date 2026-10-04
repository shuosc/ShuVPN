import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/app_info.dart';
import '../../app/shuyo_text_styles.dart';
import '../../app/theme.dart';
import '../../core/update/shu_update_client.dart';
import '../../core/update/shu_update_policy.dart';
import '../../widgets/shu_app_bar.dart';
import '../../widgets/shu_surfaces.dart';
import '../../widgets/shu_update_prompt.dart';
import 'permission_info_page.dart';

/// 设置目录页最后一行进来的地方。
///
/// 版式照 `ShuYo`（`lib/features/settings/client_settings_page.dart` 的
/// `_AboutClientPage`）逐块抄：顶部一块居中的应用标识，下面按分组铺开可点的
/// 行，末尾一段免责声明。用**分组小标题**而不是卡片 —— 它把「这是谁」和
/// 「去哪找」分开，又不用给每一组套一个圆角框。
///
/// 与原版不同的地方只有两处。一是内容：ShuYo 的「问题与反馈 / 使用条款 /
/// 隐私政策」指向它自己的后端与站点，ShuVPN 没有，所以那些行不做；
/// 「权限说明」子页里的条目按本应用真实申请的权限重写，「开源许可」是**只读**
/// 一行。二是它的「支持」组只剩「检查更新」一项，且只在安卓上出现 ——
/// 更新源是 GitHub 的 APK 发布，别的平台没有可下的东西。
class AboutPage extends StatefulWidget {
  const AboutPage({super.key});

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  /// 手动检查是否在跑。它同时是那一行的 spinner 与「先别再点」的开关。
  bool _checkingUpdate = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return Scaffold(
      appBar: ShuAppBar(
        title: '关于ShuVPN',
        onBack: () => Navigator.of(context).pop(),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
        children: [
          const _AppIdentity(),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Divider(),
          ),
          const _AboutGroupTitle('项目信息'),
          _AboutRow(
            icon: Icons.code,
            title: '源代码',
            subtitle: 'GitHub · shuosc/ShuVPN',
            onTap: () => _openExternalUrl(context, ShuAppInfo.repository),
          ),
          const _AboutRow(
            icon: Icons.balance_outlined,
            title: '开源许可',
            subtitle: ShuAppInfo.licenseName,
          ),
          _AboutRow(
            icon: Icons.inventory_2_outlined,
            title: '第三方开源许可',
            onTap: () => _showThirdPartyLicenses(context),
          ),
          _AboutRow(
            icon: Icons.groups_outlined,
            title: '贡献者',
            subtitle: '查看 GitHub Contributors',
            onTap: () => _openExternalUrl(context, ShuAppInfo.contributorsUrl),
          ),
          const SizedBox(height: 18),
          const _AboutGroupTitle('隐私与声明'),
          _AboutRow(
            icon: Icons.security_outlined,
            title: '权限说明',
            onTap: () => Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (context) => const PermissionInfoPage(),
              ),
            ),
          ),
          if (ShuUpdatePolicy.enabled) ...[
            const SizedBox(height: 18),
            const _AboutGroupTitle('支持'),
            _AboutRow(
              icon: Icons.system_update_outlined,
              title: '检查更新',
              trailing: _checkingUpdate
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    )
                  : null,
              onTap: _checkingUpdate ? null : _checkForUpdate,
            ),
          ],
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Divider(),
          ),
          Text(
            '本应用是由学生开发的非官方开源工具，与上海大学、上海大学信息办无关，'
            '不属于官方软件。\n\n'
            '${ShuAppInfo.tagline}，通过 Sangfor 协议核心建立隧道，'
            '供个人正常的校园网络访问使用。'
            '使用中遇到问题，请到 GitHub 仓库提交 issue。\n'
            '～(∠・ω< )⌒☆',
            style: ShuYoTextStyles.bodyCompact(
              color: colors.textMuted,
              height: 1.55,
            ),
          ),
        ],
      ),
    );
  }

  /// 手动查一次更新。
  ///
  /// 文案与 `ShuYo` 的 `_checkForUpdate` 一致：没有新版本、失败这两种结果都
  /// 用 snack 说，有更新才弹窗。
  Future<void> _checkForUpdate() async {
    setState(() => _checkingUpdate = true);
    try {
      final update = await context.read<ShuUpdateClient>().checkForUpdate(
        ShuAppInfo.version,
      );
      if (!mounted) return;
      if (update == null) {
        showShuSnack(context, '已是最新版本');
        return;
      }
      final openDownload = await showShuUpdatePrompt(context, update: update);
      if (!mounted || !openDownload) return;
      await openShuUpdateUrl(context, update.targetUrl);
    } on Object catch (error) {
      if (mounted) showShuSnack(context, '检查更新失败：$error');
    } finally {
      if (mounted) setState(() => _checkingUpdate = false);
    }
  }
}

/// 打开一个外部链接。
///
/// 一律走系统浏览器（`externalApplication`）：这一页上的链接最终都落在
/// GitHub 上，登录与跨站跳转交给浏览器处理更可靠。
Future<void> _openExternalUrl(BuildContext context, String url) async {
  var opened = false;
  try {
    opened = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
  } on Object {
    opened = false;
  }
  if (!opened && context.mounted) showShuSnack(context, '无法打开链接');
}

void _showThirdPartyLicenses(BuildContext context) {
  showLicensePage(
    context: context,
    applicationName: ShuAppInfo.name,
    applicationVersion: ShuAppInfo.versionLabel,
    applicationLegalese: ShuAppInfo.disclaimer,
  );
}

/// 顶部的应用标识：图标 + 名字 + 版本。
///
/// 尺寸与 ShuYo 那一块逐项相同（96 的圆角方块、22 的名字、全角括号的版本号）。
/// 图用的是**应用图标本身**（蓝底白标，与 `mipmap-*/ic_launcher.png`
/// 同一张），所以关于页上看到的就是桌面上的那一张 —— 它是不透底的方块，
/// 套 ShuYo 那层圆角与投影才是「一张图标」而不是一块飘着的图形。
class _AppIdentity extends StatelessWidget {
  const _AppIdentity();

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return Column(
      children: [
        Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.16),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: Image.asset(
              'assets/images/icon_light.png',
              width: 96,
              height: 96,
              fit: BoxFit.cover,
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          ShuAppInfo.name,
          style: ShuYoTextStyles.title(
            color: colors.textPrimary,
            size: 22,
            weight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '版本 ${ShuAppInfo.versionLabel}',
          style: ShuYoTextStyles.meta(color: colors.textMuted),
        ),
      ],
    );
  }
}

/// 一组行上面的小标题。
///
/// 小标题而不是卡片：两组之间的区别用一句话就说得清，加一层圆角边框只会
/// 让这一页看起来是两个可以拿起来的盒子。
class _AboutGroupTitle extends StatelessWidget {
  const _AboutGroupTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
      child: Text(
        title,
        style: ShuYoTextStyles.sectionTitle(
          color: context.shuyoColors.textPrimary,
        ),
      ),
    );
  }
}

/// 关于页上的一行：图标 + 标题 + 可选副标题 + 尾部。
///
/// 不复用 `SettingsRow`：那一行的副标题说的是「这一组里有什么」，而这里说的是
/// 「点下去去哪」（仓库地址、许可名），字号与颜色都不同。
///
/// [trailing] 传了就用它，没传时按 [onTap] 决定画不画箭头 —— 与本仓库里
/// `SettingsRow` 同一条规矩：箭头是「这里可以点」的承诺，只读行不画。检查更新
/// 那一行在检查期间把箭头换成 spinner，同时把 [onTap] 置空。
class _AboutRow extends StatelessWidget {
  const _AboutRow({
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: Icon(icon),
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle!),
      trailing:
          trailing ?? (onTap == null ? null : const Icon(Icons.chevron_right)),
      onTap: onTap,
    );
  }
}
