import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../widgets/settings_rows.dart';
import '../../widgets/shu_app_bar.dart';

/// 左 dock 目的地 —— 这个 VPN 能去哪些地方。
///
/// ## 为什么是「资源目录」而不是又一个设置页
///
/// 底栏三项各回答一个问题：**服务**是「我能去哪」，**连接**是「现在通不通」，
/// **设置**是「怎么连」。这一页只回答第一个，所以里面不放任何开关 —— 点一行
/// 就去了那一件事本身。
///
/// ## 每行是「图标 + 名字 + 一句它干什么」
///
/// 形状直接借设置目录页那一行（[SettingsRow]）：图标在最左是同一条竖线，扫视
/// 时不用读字就知道自己在哪一类。两页共用同一个组件不是省几行代码，而是让
/// 「可点的目录行」在全应用只有一种长相。
///
/// ## 还没做的两件事也各占一行
///
/// 测速与图书馆目录排进了路线图，但这一版没有。给它们两行、点进去说明白，
/// 比不放进列表好：用户能看见这两件事被算在里面，而不是怀疑自己找错了地方。
/// 那一页只有一句话（[ShuComingSoonPage]），不留排期。
class ServicesPage extends StatelessWidget {
  const ServicesPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: ShuAppBar(
        title: '服务',
        onNotifications: () => context.push('/notifications'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          ShuSpacing.page,
          ShuSpacing.page,
          ShuSpacing.page,
          ShuSpacing.dockInset,
        ),
        children: [
          SettingsRow(
            icon: Icons.speed_outlined,
            title: '网络测速',
            subtitle: '测隧道时延与上下行带宽',
            onTap: () => context.go('/services/speedtest'),
          ),
          SettingsRow(
            icon: Icons.local_library_outlined,
            title: '图书馆目录',
            subtitle: '图书馆的数据库与期刊目录',
            onTap: () => context.go('/services/library'),
          ),
        ],
      ),
    );
  }
}
