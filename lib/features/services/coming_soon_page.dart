import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../widgets/shu_app_bar.dart';
import '../../widgets/shu_surfaces.dart';

/// 占位页：一个已经排进路线图、但还没做的功能。
///
/// 它存在的理由是**首页那两行不能点了没反应**。选择是「不做这两行」还是
/// 「做两行、点进去说明白」—— 后者好，因为用户能看见这两件事被算在了里面，
/// 而一个不存在的入口只会让人以为找错了地方。
///
/// 页面上只有一句话，不写排期、不写「敬请期待」。说不出来的时间点就别写，
/// 写了以后每一次改期都要回来改这页。
class ShuComingSoonPage extends StatelessWidget {
  const ShuComingSoonPage({super.key, required this.title, required this.icon});

  final String title;

  /// 与首页那一行同一个图标。落进来时认得出是同一个东西。
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: ShuAppBar(
        title: title,
        onBack: () => Navigator.of(context).pop(),
      ),
      body: Padding(
        padding: const EdgeInsets.all(ShuSpacing.page),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [EmptyState(icon: icon, title: '未来版本提供服务')],
        ),
      ),
    );
  }
}
