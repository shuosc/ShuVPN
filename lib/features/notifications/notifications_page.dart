import 'package:flutter/material.dart';

import '../../app/shuyo_text_styles.dart';
import '../../app/theme.dart';
import '../../widgets/shu_app_bar.dart';

/// Matches ShuYo's tips/announcements surface. These tabs are UI placeholders;
/// opening or switching them does not fetch, cache or refresh any content.
class NotificationsPage extends StatelessWidget {
  const NotificationsPage({super.key});

  @override
  Widget build(BuildContext context) {
    const tabs = TabBar(
      tabs: [
        Tab(text: '使用提示'),
        Tab(text: '系统公告'),
      ],
    );
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: ShuAppBar(
          title: '通知',
          onBack: () => Navigator.of(context).pop(),
          bottomHeight: tabs.preferredSize.height,
          bottom: tabs,
        ),
        body: const TabBarView(
          children: [
            _ContentPlaceholder(
              storageKey: 'notification-tips',
              icon: Icons.lightbulb_outline,
              title: '暂无使用提示',
            ),
            _ContentPlaceholder(
              storageKey: 'notification-announcements',
              icon: Icons.campaign_outlined,
              title: '暂无系统公告',
            ),
          ],
        ),
      ),
    );
  }
}

class _ContentPlaceholder extends StatelessWidget {
  const _ContentPlaceholder({
    required this.storageKey,
    required this.icon,
    required this.title,
  });

  final String storageKey;
  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return ListView(
      key: PageStorageKey<String>(storageKey),
      padding: const EdgeInsets.fromLTRB(28, 96, 28, 32),
      children: [
        Icon(icon, size: 48, color: colors.textMuted),
        const SizedBox(height: 16),
        Text(
          title,
          textAlign: TextAlign.center,
          style: ShuYoTextStyles.sectionTitle(color: colors.textPrimary),
        ),
      ],
    );
  }
}
