import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../app/shuyo_text_styles.dart';
import '../../app/theme.dart';
import '../../core/announcements/shu_announcement.dart';
import '../../core/announcements/shu_announcement_client.dart';
import '../../widgets/shu_app_bar.dart';
import '../../widgets/shu_external_link.dart';
import '../../widgets/shu_surfaces.dart';

/// 「通知」—— 信息化工作办公室发布的通知公告。
///
/// ## 为什么是这一栏而不是学校官网那一栏
///
/// 官网 `shu.edu.cn/tzgg.htm` 发的是全校新闻（讲座、表彰、招生），与这个应用
/// 的用户要做的事关系不大。信息办那一栏发的是**校园网、VPN、企业微信、统一
/// 身份**这类通知 —— 用户装这个应用就是为了这几件事，网络要维护、密码要改，
/// 都在这上面写着。
///
/// ## 正文是「取 HTML + 解析」，不套 WebView
///
/// 站点没有 API，只有服务端渲染好的模板。仍然不用 WebView，理由有三个：
/// 一是 WebView 里那套排版与全应用其余页面完全不同，点进来像换了个应用；
/// 二是它的返回手势、字号缩放、深色模式都要单独伺候；三是列表页本来就是
/// 解析出来的（站点连分页都要自己算），正文再交给 WebView 等于两套东西拼在
/// 一起。代价是站点换模板时要跟着改选择器 —— 那一层集中在
/// `core/announcements/shu_announcement_parser.dart` 里，界面上不出现。
///
/// ## 列表是「滑到底自动续」
///
/// 站点一页 10 条、共 30 多页。**不画页码**：页码是桌面的东西，在手机上要点
/// 一个很小的数字才前进一页。这里滑到底就去下一屏，用的是站点自己在分页控件
/// 里给的那个链接（见 [_loadMore]），所以「到底了没有」由站点说了算，客户端
/// 不猜。
///
/// ## 每一条的正文在后台先取回来
///
/// 站点的列表项只有标题与日期，没有摘要。这一页却在每一项下面显示**两行文字
/// 预览** —— 那两行是从正文里摘的（[ShuAnnouncementDetail.preview]），所以
/// 它们要等到正文到手。拿到列表之后，这一页就按 [_prefetch] 把每一条的正文
/// 先拉回来：预览一条条长出来，而点开任意一条时正文**已经在手上**，详情页
/// 不必再等一次往返（[ShuAnnouncementClient.cachedDetail]）。
///
/// 代价是列表出来之后还要跑十次请求 —— 换来的是点进去不用等。
///
/// ## 来源那行跟着列表滑
///
/// 列表最上面是 [_SourceNotice] 说这一栏的公告出自哪里。它在列表**里面**，
/// 跟着一起滑走 —— 一句读一次就够的注解，不该占住一条常驻的位置。
///
/// ## 列表里混着外站的条目
///
/// 站点会把「换个地方看」的链接也排进这个列表，于是解析出来的地址有的不在
/// 本站。那些条目**照常显示，但不去取**（[isShuAnnouncementUrl]）：它们不是
/// 公告站的内容，拉回来也排不出正文，而一次预取十篇就等于替站点去访十个它
/// 指到的地方。点开交给系统浏览器，行末的图标也跟着换成「到外面去」。
///
/// ## 这些活一帧也不能挡
///
/// 十条正文一起回来，取、解码、解析、重画，每一步都落在用户正在滑这一页的
/// 那几秒里。所以：解码与解析在后台 isolate 上做（`ShuAnnouncementParserHost`，
/// [prefetchConcurrency] 于是只是一个速度参数，拧多大都不会挤占界面
/// isolate）；预览回一条只重画一次（[_flushPreviews]）；刷新之后上一轮的预取
/// 作废（[_prefetchEpoch]），不会有一批过期结果追着新列表写进去。
///
/// ## 列表按月份分段
///
/// 公告是流水账，日期在每条上都重复出现，一眼看不出哪几条是最近的。所以按
/// [ShuAnnouncementListItem.publishedAt] 的月份切开，每组前面一行小字
/// （[_MonthHeader]）。分组算完摊平成一维的行（[_rebuildRows]），不嵌成「每组
/// 一个列表」—— 那样懒加载会在每一组里重启，几百条一起建出来。
class NotificationsPage extends StatefulWidget {
  const NotificationsPage({super.key});

  /// 预取正文的并发数。
  ///
  /// 一页 10 条，全放出去就是 10 个并发连接。三路下一屏大约两三轮就填满了，
  /// 比一条条排队快得多，又不会为了十行摘要把站点的连接数吃满。
  ///
  /// 它只管预览多快长出来，不影响帧：解码与解析在后台 isolate 上（见
  /// `ShuAnnouncementParserHost`），回到界面 isolate 的只有合并过的一次重画
  /// （见 [_flushPreviews]）。调大只会更吃站点的连接数。
  static const int prefetchConcurrency = 3;

  /// 列表最上面那一行来源说明的 key，给测试用。
  static const Key sourceNoticeKey = ValueKey<String>(
    'notifications-source-notice',
  );

  /// 距离底部还有多少像素时开始预取下一页。
  ///
  /// 一屏大约 800 逻辑像素，600 这个值让第 10 条刚露头就开始拉下一页 ——
  /// 用户滑到底时后面那一屏通常已经到了。太小（比如 100）会让列表在到底时
  /// 空一下；太大则一进来就白拉一次。
  static const double prefetchExtent = 600;

  /// 列表底部「加载更多」那一行的 key，给测试用。
  static const Key loadMoreKey = ValueKey<String>('notification-load-more');

  /// 「没有更多了」那一行的 key，给测试用。
  static const Key listEndKey = ValueKey<String>('notification-list-end');

  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<NotificationsPage> {
  final ScrollController _scroll = ScrollController();

  /// 已经拿到的条目。
  final List<ShuAnnouncementListItem> _items = <ShuAnnouncementListItem>[];

  /// 已经出现过的地址。**按地址去重** —— 刷新与续页之间会重叠（站点按时间
  /// 倒序排，新发一条会让第 2 页的第一项变成第 1 页的最后一项）。
  final Set<String> _seen = <String>{};

  /// 下一页的地址；null = 到底了（或者还没拿到第一页）。
  Uri? _nextPage;

  /// 已经预取到的正文预览，以条目地址为键。
  ///
  /// 它比列表晚到，而且是一条条到的 —— 每一项的预览要等到它的正文回来。
  final Map<String, String> _previews = <String, String>{};

  /// 列表的行：月份小标题与公告按显示顺序摊平在一起。
  ///
  /// [_items] 一变就重算一次（见 [_rebuildRows]），而不是在 `build` 里算：
  /// 滑动与预览回来都会重建，每次摊一遍是每一帧都要付的钱。
  List<_ListRow> _rows = const <_ListRow>[];

  /// 预取的轮次。刷新会让上一轮作废 —— 那些结果属于上一份列表。
  int _prefetchEpoch = 0;

  /// 预览是不是有一批等着重画。见 [_flushPreviews]。
  bool _flushScheduled = false;

  /// 第一页正在加载 —— 整页只显示一个转圈。
  bool _loading = true;

  /// 正在续页。它同时是「别再触发一次」的锁。
  bool _loadingMore = false;

  /// 第一页失败的原因。有值时整页显示它（列表此时必然为空）。
  Object? _error;

  /// 首帧之后才去取数据：`context.read` 不能在 `initState` 里跑。
  bool _started = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _scroll.addListener(_onScroll);
    unawaited(_loadFirstPage());
  }

  @override
  void dispose() {
    _scroll
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    if (position.pixels <
        position.maxScrollExtent - NotificationsPage.prefetchExtent) {
      return;
    }
    if (_nextPage == null || _loadingMore || _loading) return;
    unawaited(_loadMore());
  }

  Future<void> _loadFirstPage() async {
    final client = context.read<ShuAnnouncementClient>();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await client.fetchList();
      if (!mounted) return;
      // 第一页是整份替换，去重的账要从头记 —— 不清空的话刷新回来的每一条都
      // 会被当成「已经见过」，列表会当场变空。
      _seen.clear();
      final fresh = _dedupe(page.items);
      // 从这一刻起上一轮的预取算过期：它手上那份是旧列表的条目。
      _prefetchEpoch++;
      setState(() {
        _items
          ..clear()
          ..addAll(fresh);
        _nextPage = page.nextPage;
        _loading = false;
        _rebuildRows();
      });
      unawaited(_prefetch(fresh));
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  /// 续页。
  ///
  /// 失败**不清空已经拿到的条目**，也不把 [_nextPage] 丢掉 —— 用户滑到的位置
  /// 是他自己的进度，一次请求失败不该把它抹掉。下一次滑到底会自动再试。
  Future<void> _loadMore() async {
    final next = _nextPage;
    if (next == null) return;
    final client = context.read<ShuAnnouncementClient>();
    setState(() => _loadingMore = true);
    try {
      final page = await client.fetchList(page: next);
      if (!mounted) return;
      final fresh = _dedupe(page.items);
      setState(() {
        _items.addAll(fresh);
        // 空页却还带「下页」时停下：继续跟下去就是死循环。
        _nextPage = page.items.isEmpty ? null : page.nextPage;
        _loadingMore = false;
        _rebuildRows();
      });
      unawaited(_prefetch(fresh));
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
      showShuSnack(context, '加载更多失败：$error');
    }
  }

  /// 把 [items] 的正文先取回来，顺手把预览填上。
  ///
  /// 失败是**静默**的：没有预览的那一项只是少两行字，它自己也好好的 —— 为了
  /// 一行摘要弹一条报错，比那两行字没出来更像个故障。点开时详情页会再拉一次
  /// （那条路会报错，也会让用户重试）。
  ///
  /// 三个 worker 抢一个游标而不是 `Future.wait(items)`：**顺序**才有意义，写
  /// 在前面的那几篇先有预览，用户最先看的就是它们。
  Future<void> _prefetch(List<ShuAnnouncementListItem> items) async {
    if (items.isEmpty) return;
    final client = context.read<ShuAnnouncementClient>();
    final epoch = _prefetchEpoch;
    var cursor = 0;

    Future<void> worker() async {
      while (mounted && epoch == _prefetchEpoch) {
        final index = cursor++;
        if (index >= items.length) return;
        final item = items[index];
        final key = item.url.toString();
        // 外站的条目不取（见 isShuAnnouncementUrl）—— 去了也排不出正文，
        // 而且那是别人的站。它们没有预览。
        if (!isShuAnnouncementUrl(item.url)) continue;
        // 下拉刷新拉回来的还是那几条，它们的预览已经在手上。
        if (_previews.containsKey(key)) continue;
        try {
          final detail = await client.fetchDetail(item);
          if (!mounted || epoch != _prefetchEpoch) return;
          final preview = detail.preview;
          if (preview.isEmpty) continue;
          _previews[key] = preview;
          _flushPreviews();
        } on Object {
          // 见上：预取失败不打扰用户。
        }
      }
    }

    await Future.wait<void>(<Future<void>>[
      for (
        var index = 0;
        index < NotificationsPage.prefetchConcurrency;
        index++
      )
        worker(),
    ]);
  }

  /// 把攒下的预览合成一次重画。
  ///
  /// 并发的那几篇正文可能落在同一个事件轮里，一条一次 `setState` 就是同一帧
  /// 里连着重建几遍列表。攒到微任务里只重画一次；微任务先于下一帧，所以该
  /// 出现的那一帧不会晚。
  void _flushPreviews() {
    if (_flushScheduled) return;
    _flushScheduled = true;
    scheduleMicrotask(() {
      _flushScheduled = false;
      if (mounted) setState(() {});
    });
  }

  /// 按月份把列表切成组，每组第一行之前插一个小标题。
  ///
  /// 站点按时间倒序给，所以「月份和上一条不同」就是新的一组 —— 不先排序，也不
  /// 假设它一定有序：顺序变了只是多一个小标题。缺日期的那一条不补标题，跟着
  /// 上一组（站点每一篇都有日期，这是兜底）。
  void _rebuildRows() {
    if (_items.isEmpty) {
      _rows = const <_ListRow>[];
      return;
    }
    final rows = <_ListRow>[const _NoticeRow()];
    var year = -1;
    var month = -1;
    for (final item in _items) {
      final at = item.publishedAt;
      if (at != null && (at.year != year || at.month != month)) {
        year = at.year;
        month = at.month;
        rows.add(_MonthRow('$year年 $month月'));
      }
      rows.add(_ItemRow(item));
    }
    _rows = rows;
  }

  /// 过滤掉已经在列表里的地址，返回真正的新的那些。
  List<ShuAnnouncementListItem> _dedupe(List<ShuAnnouncementListItem> items) {
    final fresh = <ShuAnnouncementListItem>[];
    for (final item in items) {
      if (_seen.add(item.url.toString())) fresh.add(item);
    }
    return fresh;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: ShuAppBar(title: '通知', onBack: () => Navigator.of(context).pop()),
      body: RefreshIndicator(onRefresh: _loadFirstPage, child: _body()),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 3));
    }
    final error = _error;
    if (error != null && _items.isEmpty) {
      return _scrollableEmpty(
        icon: Icons.cloud_off_outlined,
        title: '通知公告加载失败',
        message: '$error',
        action: FilledButton(
          onPressed: _loadFirstPage,
          child: const Text('重试'),
        ),
      );
    }
    if (_items.isEmpty) {
      return _scrollableEmpty(
        icon: Icons.campaign_outlined,
        title: '暂无公告',
        message: '信息化工作办公室暂时没有发布通知。',
      );
    }
    return ListView.separated(
      controller: _scroll,
      physics: const AlwaysScrollableScrollPhysics(),
      // 底部留出底栏的高度（`DockShell` 的 `extendBody` 会把内容垫到栏下面），
      // 续页那一行也落在这个内边距里。
      padding: const EdgeInsets.fromLTRB(
        ShuSpacing.page,
        8,
        ShuSpacing.page,
        ShuSpacing.dockInset,
      ),
      // 末尾多一格：续页的转圈、「加载更多」、或者「没有更多了」。
      itemCount: _rows.length + 1,
      separatorBuilder: _separator,
      itemBuilder: (context, index) {
        if (index == _rows.length) return _footer();
        return switch (_rows[index]) {
          _NoticeRow() => const _SourceNotice(),
          _MonthRow(:final label) => _MonthHeader(label),
          _ItemRow(:final item) => _AnnouncementTile(
            item: item,
            preview: _previews[item.url.toString()],
            external: !isShuAnnouncementUrl(item.url),
            onTap: () => _open(item),
          ),
        };
      },
    );
  }

  /// 月份小标题的上下不画线：它自己就是一道分隔，再描一条边看着像把标题框进
  /// 了上一组。
  Widget _separator(BuildContext context, int index) {
    if (_rows[index] is _MonthRow) return const SizedBox.shrink();
    if (index + 1 < _rows.length && _rows[index + 1] is _MonthRow) {
      return const SizedBox.shrink();
    }
    return Divider(height: 1, color: context.shuyoColors.border);
  }

  /// 打开一条公告。
  ///
  /// 本站的进详情页；外站的**交给系统浏览器** —— 那些条目这一页不取，也就没
  /// 有正文可以排，而它本来就是一个「去别处看」的地址。
  void _open(ShuAnnouncementListItem item) {
    if (!isShuAnnouncementUrl(item.url)) {
      unawaited(openShuExternalUrl(context, item.url));
      return;
    }
    context.push('/notifications/detail', extra: item);
  }

  Widget _footer() {
    if (_loadingMore) {
      return const Padding(
        key: NotificationsPage.loadMoreKey,
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
        ),
      );
    }
    if (_nextPage != null) {
      // 还剩下一页但没在拉：给一根可点的行，滑不动的时候也能手动续
      // （自动预取失败之后停在的就是这一态）。
      return InkWell(
        onTap: _loadMore,
        child: const Padding(
          key: NotificationsPage.loadMoreKey,
          padding: EdgeInsets.symmetric(vertical: 18),
          child: Center(child: Text('加载更多')),
        ),
      );
    }
    return Padding(
      key: NotificationsPage.listEndKey,
      padding: const EdgeInsets.only(top: 18),
      child: Center(
        child: Text(
          '没有更多了',
          style: ShuYoTextStyles.meta(color: context.shuyoColors.textMuted),
        ),
      ),
    );
  }

  /// 空态也要能下拉刷新 —— `RefreshIndicator` 需要孩子本身可滚。
  Widget _scrollableEmpty({
    required IconData icon,
    required String title,
    String? message,
    Widget? action,
  }) {
    return LayoutBuilder(
      builder: (context, box) => ListView(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(
            height: box.maxHeight,
            child: Padding(
              padding: const EdgeInsets.all(ShuSpacing.page),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  EmptyState(
                    icon: icon,
                    title: title,
                    message: message,
                    action: action,
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

/// 列表最上面那一行来源说明。
///
/// 它跟着列表一起滑走，不是一条常驻的标题：这一句说的是这一栏的出处，读一次
/// 就够了。
///
/// 唯一一行字，不给链接（也不给下划线）：这是一句注解，不是入口 —— 想去看原
/// 站的人可以从详情页顶栏那个按钮进，那里打开的就是站点原文。地址不写
/// `https://`：注明出处用不着协议头，省下的宽度让这一行在窄屏上也放得下。
/// 真放不下时截断而不换行（[TextOverflow.ellipsis]）—— 换成两行就等于把第一
/// 条公告往下压一格。
class _SourceNotice extends StatelessWidget {
  const _SourceNotice();

  /// 站点这一栏的出处：信息化工作办公室对外的站。
  static const String label = '通知来源：上海大学信息化工作办公室 newits.shu.edu.cn';

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: NotificationsPage.sourceNoticeKey,
      padding: const EdgeInsets.only(top: 10, bottom: 2),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: ShuYoTextStyles.meta(color: context.shuyoColors.textMuted),
      ),
    );
  }
}

/// 列表里的一行：来源说明、月份小标题，或者一条公告。
///
/// 摊平成一维而不是「每组一个列表」：分组只是显示上的事，滚动还是一份，
/// `ListView` 的懒加载也还是一份。
sealed class _ListRow {
  const _ListRow();
}

/// 最上面那行来源说明。
class _NoticeRow extends _ListRow {
  const _NoticeRow();
}

/// 某个月的小标题行。
class _MonthRow extends _ListRow {
  const _MonthRow(this.label);

  /// `2026年 9月` 这样的一行字。
  final String label;
}

/// 一条公告。
class _ItemRow extends _ListRow {
  const _ItemRow(this.item);

  final ShuAnnouncementListItem item;
}

/// 月份小标题。
///
/// 比标题小一号、颜色浅一档 —— 它是分组的分隔，不该跟公告标题抢注意力。
class _MonthHeader extends StatelessWidget {
  const _MonthHeader(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 4),
      child: Text(
        label,
        style: ShuYoTextStyles.meta(
          color: context.shuyoColors.textSecondary,
          size: 12.5,
          weight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 列表里的一行：标题 + 两行预览 + 日期。
///
/// 预览比日期晚到（正文还在预取的路上），所以这一行是**会自己长高**的。不给
/// 它预先占位是有意的：占位会让每一行在预取失败时都留下一块空白，而这里的
/// 失败是静默的 —— 少两行字看得过去，一块空格子不好解释。
///
/// [external] 的那一条不会长高（它没有预览），行末也换一个图标：那一个是
/// 「到外面去」而不是「展开详情」。
class _AnnouncementTile extends StatelessWidget {
  const _AnnouncementTile({
    required this.item,
    required this.preview,
    required this.external,
    required this.onTap,
  });

  final ShuAnnouncementListItem item;

  /// 从正文开头摘的那两行；null = 还没预取到（或者预取失败）。
  final String? preview;

  /// 这一条指向别的站：不取正文，点开交给浏览器。
  final bool external;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    final text = preview;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 15),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: ShuYoTextStyles.title(
                      color: colors.textPrimary,
                      size: 16,
                      height: 1.26,
                      weight: FontWeight.w500,
                    ),
                  ),
                  if (text != null && text.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      text,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: ShuYoTextStyles.bodyCompact(
                        color: colors.textTertiary,
                        size: 13.5,
                        height: 1.46,
                      ),
                    ),
                  ],
                  if (item.dateText.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      item.dateText,
                      style: ShuYoTextStyles.meta(color: colors.textMuted),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 10),
            Icon(
              external ? Icons.open_in_new : Icons.chevron_right,
              size: external ? 18 : 24,
              color: colors.textMuted,
            ),
          ],
        ),
      ),
    );
  }
}
