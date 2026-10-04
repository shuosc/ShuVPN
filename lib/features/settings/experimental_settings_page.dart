import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../app/router.dart';
import '../../core/connection/connection_controller.dart';
import '../../core/settings/settings_store.dart';
import '../../widgets/settings_rows.dart';
import '../../widgets/settings_scaffold.dart';
import '../../widgets/shu_surfaces.dart';

/// 「实验性选项」。
///
/// 这里放两类东西：**值得给用户留一条退路的取值**，以及那些「走回一遍」的
/// 入口。
///
/// 与「网络连接」那一页一样，隧道跑着的时候整页封住（见
/// [shuSettingsLockedNotice]）：窗口那一格在 `startVpn()` 里被读走，而重走
/// 引导会重新登录、把连接整个拆掉 —— 让它们在运行期可点，只会得到「界面
/// 变了、跑着的东西没变」这种最难查的状态。
class ShuExperimentalSettingsPage extends StatelessWidget {
  const ShuExperimentalSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsStore>();
    final locked = context.watch<ConnectionController>().tunnelUp;

    return ShuSettingsSubPage(
      title: '实验性选项',
      banner: locked ? const ShuNoticeBar(shuSettingsLockedNotice) : null,
      children: [
        const SectionHeader(title: '系统 VPN'),
        SettingsSwitchRow(
          icon: Icons.swap_horiz,
          title: 'TCP 接收窗口缩放',
          subtitle: settings.vpnTcpWindowScaling ? '1 MiB' : '64 KB',
          value: settings.vpnTcpWindowScaling,
          enabled: !locked,
          onChanged: (value) => settings.vpnTcpWindowScaling = value,
        ),
        const ShuSettingsNote(
          '只影响系统 VPN 那一半：它的 TCP 由本机终结器逐流接管，'
          '终结器通告给本机协议栈的接收窗口就是每条连接的在途上限。'
          '16 位窗口字段最多认 64 KB，而这段往返走的是应用自己的事件循环，'
          '于是「64 KB ÷ 往返」成了单连接吞吐的天花板 —— 应用越忙它越低。',
        ),

        const SectionHeader(title: '引导'),
        SettingsRow(
          icon: Icons.tour_outlined,
          title: '新用户引导',
          enabled: !locked,
          onTap: () => _replayOnboarding(context),
        ),
      ],
    );
  }

  /// 重新走一遍新用户引导。
  ///
  /// 清掉 `welcomeCompleted`，路由的重定向于是把界面锁在引导页上 —— 三页
  /// 走完（含重新登录）之前回不到主页，所以先问一次。
  Future<void> _replayOnboarding(BuildContext context) async {
    final settings = context.read<SettingsStore>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('重新开始引导'),
        content: const Text('引导完成前无法返回主页，完成后需要重新登录校园账户。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('重新开始'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    // 写标记必须在 `go` 之前：路由的重定向会读它。
    settings.welcomeCompleted = false;
    context.go(shuWelcomePath);
  }
}
