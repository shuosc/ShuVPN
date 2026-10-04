import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/shuyo_text_styles.dart';
import '../../app/theme.dart';
import '../../core/announcements/shu_announcement.dart';
import '../../core/announcements/shu_announcement_client.dart';
import '../../widgets/shu_app_bar.dart';
import '../../widgets/shu_external_link.dart';
import '../../widgets/shu_surfaces.dart';

/// 正文两侧的内边距。图片的解码宽度也按它算。
const double _detailPadding = 20;

/// 图片解码出来之前占的高度。
///
/// 不给占位的话正文会在图片到达时从零高度跳一下 —— 用户正在读的那一段会被
/// 顶走，而那多半就是图片上面那一行。
const double _imagePlaceholderHeight = 180;

/// 一条公告的正文。
///
/// 内容来自 `core/announcements` 解析出来的块序列（段落 / 图片 / 附件），
/// 这一页只负责把它排出来 —— 选择器与站点结构的知识全在解析器里，这个文件
/// 不认识 HTML。
class AnnouncementDetailPage extends StatefulWidget {
  const AnnouncementDetailPage({super.key, required this.item});

  /// 列表里点中的那一项。
  ///
  /// 标题与日期由它带进来，所以正文还在路上时页面上已经有标题了 —— 不必等
  /// 一次往返才告诉用户他点开的是哪一篇。
  final ShuAnnouncementListItem item;

  /// 图片占位那个方块的 key，给测试用。
  static const Key imagePlaceholderKey = ValueKey<String>(
    'announcement-image-placeholder',
  );

  @override
  State<AnnouncementDetailPage> createState() => _AnnouncementDetailPageState();
}

class _AnnouncementDetailPageState extends State<AnnouncementDetailPage> {
  /// 已经预取到的正文。非 null 时这一页**同步**就能画出来。
  ShuAnnouncementDetail? _cached;

  Future<ShuAnnouncementDetail>? _future;

  /// 请求在 `didChangeDependencies` 里发起：`context.read` 不能在
  /// `initState` 里跑，而这里只跑一次（两个字段都判空）。
  ///
  /// 先问缓存：通知页在列表阶段就把正文取回来了（为了那两行预览），所以从
  /// 列表点进来时它多半已经在手上了 —— 那一趟就是「点开即读」。缓存里没有
  /// （直接从深链接进来、或者预取刚失败过）才发请求。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_cached != null || _future != null) return;
    final client = context.read<ShuAnnouncementClient>();
    final cached = client.cachedDetail(widget.item.url);
    if (cached != null) {
      _cached = cached;
      return;
    }
    _future = client.fetchDetail(widget.item);
  }

  Future<ShuAnnouncementDetail> _load() =>
      context.read<ShuAnnouncementClient>().fetchDetail(widget.item);

  /// ⚠️ 必须是**块**而不是 `=> setState(() => _future = _load())`：箭头函数
  /// 会把赋值的结果（一个 `Future`）当成 `setState` 回调的返回值，而框架对此
  /// 有断言（「回调返回了 Future，是不是写成 async 了」）。
  void _retry() {
    setState(() {
      _future = _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: ShuAppBar(
        title: '通知详情',
        onBack: () => Navigator.of(context).pop(),
        actions: [
          IconButton(
            tooltip: '在浏览器中打开',
            // 与列表里外站条目行末那个图标同一个：两处点下去都是把页面交给
            // 系统浏览器，图标不该换个样子。
            icon: const Icon(Icons.open_in_new),
            onPressed: () => openShuExternalUrl(context, widget.item.url),
          ),
        ],
      ),
      body: _body(),
    );
  }

  Widget _body() {
    // 缓存命中时**不经过 `FutureBuilder`**：它至少会给出一帧「还没完成」的
    // 状态，而正文已经在手上了，那一帧的转圈只是白闪一下。
    final cached = _cached;
    if (cached != null) return _DetailBody(detail: cached);
    return FutureBuilder<ShuAnnouncementDetail>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator(strokeWidth: 3));
        }
        final error = snapshot.error;
        if (error != null) {
          return Padding(
            padding: const EdgeInsets.all(ShuSpacing.page),
            child: Center(
              child: EmptyState(
                icon: Icons.cloud_off_outlined,
                title: '公告加载失败',
                message: '$error',
                action: FilledButton(
                  onPressed: _retry,
                  child: const Text('重试'),
                ),
              ),
            ),
          );
        }
        return _DetailBody(detail: snapshot.data!);
      },
    );
  }
}

class _DetailBody extends StatelessWidget {
  const _DetailBody({required this.detail});

  final ShuAnnouncementDetail detail;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    final images = detail.blocks
        .whereType<ShuAnnouncementImage>()
        .map((block) => block.url)
        .toList(growable: false);
    // 每张图在 `images` 里的位置先算好：放到 `List.generate` 里再 `indexOf`
    // 就是一边构建一边线性查找。
    final imageIndex = <int, int>{};
    for (var index = 0; index < detail.blocks.length; index++) {
      if (detail.blocks[index] is ShuAnnouncementImage) {
        imageIndex[index] = imageIndex.length;
      }
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        _detailPadding,
        16,
        _detailPadding,
        32,
      ),
      children: [
        Text(
          detail.title,
          style: ShuYoTextStyles.title(
            color: colors.textPrimary,
            size: 20,
            height: 1.22,
            weight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 12),
        _Metadata(detail: detail),
        const SizedBox(height: 22),
        if (!detail.hasContent)
          Text(
            '这篇公告没有解析到正文。',
            style: ShuYoTextStyles.body(color: colors.textTertiary),
          )
        else
          for (var index = 0; index < detail.blocks.length; index++)
            _block(context, detail.blocks[index], images, imageIndex[index]),
      ],
    );
  }

  Widget _block(
    BuildContext context,
    ShuAnnouncementBlock block,
    List<String> images,
    int? index,
  ) {
    final colors = context.shuyoColors;
    final bodyStyle = ShuYoTextStyles.body(
      color: colors.textPrimary,
      size: 16,
      height: 1.7,
    );
    return switch (block) {
      // 没有链接的段落走 `SelectableText`（公告里的邮箱、电话常要被抄下来）；
      // 带链接的那一种看 `_AnnouncementParagraph` 上的说明。
      ShuAnnouncementText(:final text, :final inlines) => Padding(
        padding: const EdgeInsets.only(bottom: 13),
        child: inlines.isEmpty
            ? SelectableText(text, style: bodyStyle)
            : _AnnouncementParagraph(
                inlines: inlines,
                style: bodyStyle,
                linkStyle: _linkStyle(colors, bodyStyle),
              ),
      ),
      ShuAnnouncementImage(:final url, :final alt) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: _DetailImage(
          url: url,
          alt: alt,
          images: images,
          index: index ?? 0,
        ),
      ),
      ShuAnnouncementTable(:final rows, :final hasHeaderRow) =>
        _AnnouncementTableBlock(rows: rows, hasHeaderRow: hasHeaderRow),
      ShuAnnouncementAttachment(:final name, :final url) => _AttachmentRow(
        name: name,
        url: url,
      ),
    };
  }
}

/// 正文里链接的样式。
///
/// 换色加下划线，而不是只把字变蓝：链接夹在一整段正文中间，不给下划线时它就
/// 只是一串颜色不同的字，得读一遍才知道那是能点的。站点的网页版给的也是这个
/// 样子，用户对「这一段能点」的预期就从那里来。
TextStyle _linkStyle(ShuYoColors colors, TextStyle body) => body.copyWith(
  color: colors.accent,
  decoration: TextDecoration.underline,
  decorationColor: colors.accent,
);

/// 一段可能带链接的正文文字。
///
/// 链接用 `TextSpan.recognizer`（[TapGestureRecognizer]）而不是 `WidgetSpan`
/// 加 `GestureDetector`：后者把链接变成一个原子盒子，句子在它两边断开，换行
/// 也跟着走样 —— 而站点的链接是嵌在句子中间的（`请点击这里：<a>邮箱申请</a>。`）。
///
/// 带链接的段落因此走 `Text.rich` 而不是 `SelectableText` —— 后者把文字交给
/// 选择系统，点不到 `recognizer`。两者不能兼得时选了链接：公告里那些链接是
/// 「去办事」的入口，而复制一段公告文字是偶发的事。
class _AnnouncementParagraph extends StatefulWidget {
  const _AnnouncementParagraph({
    required this.inlines,
    required this.style,
    required this.linkStyle,
  });

  final List<ShuAnnouncementInline> inlines;
  final TextStyle style;
  final TextStyle linkStyle;

  @override
  State<_AnnouncementParagraph> createState() => _AnnouncementParagraphState();
}

class _AnnouncementParagraphState extends State<_AnnouncementParagraph> {
  /// 每个链接一个识别器。
  ///
  /// 它必须显式 `dispose`（握着指针路由的注册），而 `TextSpan` 是不可变的 ——
  /// 换一次样式或地址只能重搭一棵树，所以旧的在这里一起放掉。
  final List<TapGestureRecognizer> _recognizers = <TapGestureRecognizer>[];

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  @override
  Widget build(BuildContext context) {
    _disposeRecognizers();
    final spans = <InlineSpan>[];
    for (final inline in widget.inlines) {
      final url = inline.url;
      if (url == null) {
        spans.add(TextSpan(text: inline.text));
        continue;
      }
      final recognizer = TapGestureRecognizer()
        ..onTap = () => openShuExternalUrl(context, url);
      _recognizers.add(recognizer);
      spans.add(
        TextSpan(
          text: inline.text,
          style: widget.linkStyle,
          recognizer: recognizer,
        ),
      );
    }
    return Text.rich(TextSpan(style: widget.style, children: spans));
  }
}

/// 正文里的一张表。
///
/// 列宽一律**均分**（`FlexColumnWidth`）：站点那些表是 Word 里排好的，列宽
/// 按磅写死，照搬到手机上要么横向溢出、要么把某一列压成一条。均分之后表在屏幕
/// 宽度里排得下，长文字在格子里换行 —— 表会长，但不会撑破页面，也不需要用户
/// 横着滑。
///
/// 表头只换底色与字重，不再给第一行描一圈：整张表已经是网格了，再加边框看起来
/// 就像里面又套了一张小表。
class _AnnouncementTableBlock extends StatelessWidget {
  const _AnnouncementTableBlock({
    required this.rows,
    required this.hasHeaderRow,
  });

  final List<List<ShuAnnouncementTableCell>> rows;
  final bool hasHeaderRow;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    final style = ShuYoTextStyles.body(
      color: colors.textPrimary,
      size: 14,
      height: 1.5,
    );
    final headerStyle = style.copyWith(fontWeight: FontWeight.w600);
    final linkStyle = _linkStyle(colors, style);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(ShuRadii.tile),
        child: Table(
          border: TableBorder.all(color: colors.border),
          defaultColumnWidth: const FlexColumnWidth(),
          defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          children: <TableRow>[
            for (var index = 0; index < rows.length; index++)
              TableRow(
                decoration: hasHeaderRow && index == 0
                    ? BoxDecoration(color: colors.surfaceAlt)
                    : null,
                children: <Widget>[
                  for (final cell in rows[index])
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 9,
                      ),
                      child: _AnnouncementParagraph(
                        inlines: cell.inlines,
                        style: hasHeaderRow && index == 0 ? headerStyle : style,
                        linkStyle: linkStyle,
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// 正文里的一张图。
///
/// 点开时把**整篇的图**一起交给全屏页，初始位置是这一张 —— 学校公告里的图
/// 常常是连着好几张的附件截图，一张张退出来再点下一张很难用。
class _DetailImage extends StatelessWidget {
  const _DetailImage({
    required this.url,
    required this.alt,
    required this.images,
    required this.index,
  });

  final String url;
  final String alt;
  final List<String> images;
  final int index;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    // 按实际显示的宽度解码：公告里的图常常宽过 1000 像素，原尺寸解码会在
    // 滚动与转场时占满光栅线程。
    final logicalWidth = MediaQuery.sizeOf(context).width - _detailPadding * 2;
    final cacheWidth = (logicalWidth * MediaQuery.devicePixelRatioOf(context))
        .round();
    return GestureDetector(
      onTap: () => Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (context) =>
              _FullscreenImage(urls: images, initialIndex: index),
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(ShuRadii.tile),
        child: Image.network(
          url,
          fit: BoxFit.cover,
          cacheWidth: cacheWidth,
          semanticLabel: alt.isEmpty ? null : alt,
          frameBuilder: (context, child, frame, loaded) {
            if (loaded || frame != null) return child;
            return const SizedBox(
              key: AnnouncementDetailPage.imagePlaceholderKey,
              height: _imagePlaceholderHeight,
              width: double.infinity,
            );
          },
          errorBuilder: (context, error, stackTrace) => Container(
            height: 120,
            alignment: Alignment.center,
            color: colors.surfaceAlt,
            child: Text(
              '图片加载失败',
              style: ShuYoTextStyles.meta(color: colors.textTertiary),
            ),
          ),
        ),
      ),
    );
  }
}

/// 正文末尾的附件。点一下交给浏览器下载。
///
/// 下载走系统浏览器而不是应用内缓存：这些是 `.rar` / `.docx`，应用里没有能
/// 打开它们的东西，交给浏览器之后用户的手势与其它下载是一致的。
class _AttachmentRow extends StatelessWidget {
  const _AttachmentRow({required this.name, required this.url});

  final String name;
  final Uri url;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: ShuCard(
        padding: EdgeInsets.zero,
        child: ListTile(
          leading: const Icon(Icons.attach_file),
          title: Text(
            name,
            style: ShuYoTextStyles.bodyCompact(color: colors.textPrimary),
          ),
          subtitle: Text(
            '下载附件',
            style: ShuYoTextStyles.meta(color: colors.textTertiary),
          ),
          trailing: const Icon(Icons.download_outlined),
          onTap: () => openShuExternalUrl(context, url),
        ),
      ),
    );
  }
}

class _Metadata extends StatelessWidget {
  const _Metadata({required this.detail});

  final ShuAnnouncementDetail detail;

  @override
  Widget build(BuildContext context) {
    final parts = [
      if (detail.dateText.isNotEmpty) detail.dateText,
      if (detail.author.isNotEmpty) detail.author,
    ];
    if (parts.isEmpty) return const SizedBox.shrink();
    return Text(
      parts.join(' · '),
      style: ShuYoTextStyles.meta(color: context.shuyoColors.textTertiary),
    );
  }
}

/// 全屏看图，左右滑动切换。
class _FullscreenImage extends StatefulWidget {
  const _FullscreenImage({required this.urls, required this.initialIndex});

  final List<String> urls;
  final int initialIndex;

  @override
  State<_FullscreenImage> createState() => _FullscreenImageState();
}

class _FullscreenImageState extends State<_FullscreenImage> {
  late final PageController _pages = PageController(
    initialPage: widget.initialIndex,
  );
  late int _index = widget.initialIndex;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          '${_index + 1} / ${widget.urls.length}',
          style: ShuYoTextStyles.headerTitle(color: Colors.white),
        ),
      ),
      body: PageView.builder(
        controller: _pages,
        itemCount: widget.urls.length,
        onPageChanged: (index) => setState(() => _index = index),
        itemBuilder: (context, index) =>
            InteractiveViewer(child: Image.network(widget.urls[index])),
      ),
    );
  }
}
