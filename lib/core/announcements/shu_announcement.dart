/// 一条公告在列表里的样子。
///
/// 来源是信息化工作办公室站点（VSB CMS）的列表页，那一页每项只有标题与日期，
/// 没有摘要 —— 所以这里也没有。补齐摘要要在列表阶段把每篇正文都拉一遍，
/// 代价是一个 10 项的列表变成 11 次请求。
class ShuAnnouncementListItem {
  const ShuAnnouncementListItem({
    required this.title,
    required this.url,
    this.dateText = '',
    this.publishedAt,
  });

  final String title;

  /// 绝对地址。列表页给的是 `../../info/1095/6132.htm` 这种相对路径，
  /// 解析时必须按**那一页自己的**地址展开（见 `parseAnnouncementList`）。
  final Uri url;

  /// 站点上原样的日期文本（`2025-09-22`），列表里直接显示它。
  final String dateText;

  /// [dateText] 解析出来的日期，解析不出为 null。
  final DateTime? publishedAt;
}

/// 公告正文里的一块内容。
///
/// 正文是一段混合序列（段落、图片、表格、附件），拆成有序的块而不是一个富文本
/// 字符串：Flutter 里没有现成的 HTML 渲染器，而把 `<img>` 塞进文字流会同时
/// 丢掉图片的加载状态与点击放大；表格混在文字流里同样排不出来。
sealed class ShuAnnouncementBlock {
  const ShuAnnouncementBlock();
}

/// 正文里的一小段文字。
///
/// 站点把申请入口、相关通知这类地址直接写在句子中间
/// （`如需申请本校邮箱，请点击这里：<a>上海大学邮箱申请</a>。`），所以一段
/// 文字不是一个字符串，而是若干片段按文档顺序排下来的序列。
class ShuAnnouncementInline {
  const ShuAnnouncementInline(this.text, {this.url});

  final String text;

  /// 片段指向的地址；null 表示它只是普通文字。
  final Uri? url;

  bool get isLink => url != null;
}

class ShuAnnouncementText extends ShuAnnouncementBlock {
  /// 一个没有链接的段落。
  const ShuAnnouncementText(this.text)
    : inlines = const <ShuAnnouncementInline>[];

  /// 带链接的段落，片段按文档顺序排。
  const ShuAnnouncementText.rich(this.inlines) : text = '';

  /// 纯文字段落的内容。带链接的段落这里是空串 —— 那种段落一律读 [plainText]。
  final String text;

  /// 段落里的片段；没有链接时为空，此时整段就是 [text]。
  final List<ShuAnnouncementInline> inlines;

  /// 段落最终显示的文字，不论有没有链接。
  String get plainText =>
      inlines.isEmpty ? text : inlines.map((inline) => inline.text).join();
}

class ShuAnnouncementImage extends ShuAnnouncementBlock {
  const ShuAnnouncementImage(this.url, {this.alt = ''});

  final String url;
  final String alt;
}

/// 表格里的一个格子。
///
/// 格子里也可以有链接 —— 表格里的「点击这里」与正文里的一样多。
class ShuAnnouncementTableCell {
  const ShuAnnouncementTableCell(this.inlines);

  /// 空格子。`colspan` 合并出来的那几格与短行都用它补齐。
  static const ShuAnnouncementTableCell empty = ShuAnnouncementTableCell(
    <ShuAnnouncementInline>[],
  );

  final List<ShuAnnouncementInline> inlines;

  String get plainText => inlines.map((inline) => inline.text).join();
}

/// 正文里的一张表。
///
/// 站点的通知常带一张 Word 贴过来的表（资产清查的模版、竞赛的赛项安排）。
/// 模板把表格直接排在正文里，所以它是一块**块级**内容 —— 混在文字流里排不
/// 出来，得自己占一段。
class ShuAnnouncementTable extends ShuAnnouncementBlock {
  const ShuAnnouncementTable({required this.rows, this.hasHeaderRow = false});

  /// 行 × 列。
  ///
  /// 每行**等长**：`colspan` 合并出来的格子与短行都用
  /// [ShuAnnouncementTableCell.empty] 补齐了。Flutter 的 `Table` 要求所有行
  /// 列数一致，不补齐会在渲染时抛断言。
  final List<List<ShuAnnouncementTableCell>> rows;

  /// 第一行是表头。
  ///
  /// 站点用 `<tr class="firstRow">` 标出这一行（Word 转出来的标记），也有
  /// `<th>` 的写法，两种都认。
  final bool hasHeaderRow;
}

/// 正文末尾的附件下载项（`download.jsp?…`）。
class ShuAnnouncementAttachment extends ShuAnnouncementBlock {
  const ShuAnnouncementAttachment(this.name, this.url);

  final String name;
  final Uri url;
}

/// 一篇公告的正文。
class ShuAnnouncementDetail {
  const ShuAnnouncementDetail({
    required this.title,
    required this.url,
    required this.blocks,
    this.dateText = '',
    this.publishedAt,
    this.author = '',
  });

  final String title;
  final Uri url;
  final List<ShuAnnouncementBlock> blocks;
  final String dateText;
  final DateTime? publishedAt;

  /// 详情页 `创建时间：` 后面那个署名（VSB 模板的「作者」栏）。
  final String author;

  bool get hasContent => blocks.isNotEmpty;

  /// 列表里那两行文字预览用的内容。
  ///
  /// 站点的列表页没有摘要，所以它是**从正文开头摘的** —— 列表要显示它就意味
  /// 着这一篇的正文已经被拉下来了（见 `NotificationsPage` 的预取）。
  ///
  /// 摘到 [previewLength] 个字为止，超过就截断加省略号。图片与表格不贡献文字：
  /// 它们是图不是话，放进两行的预览里只会让开头变成一句没头没尾的话。
  String get preview {
    final buffer = StringBuffer();
    for (final block in blocks) {
      if (block is! ShuAnnouncementText) continue;
      final text = block.plainText;
      if (text.isEmpty) continue;
      buffer.write(text);
      if (buffer.length >= previewLength) break;
    }
    final text = buffer.toString().trim();
    if (text.isEmpty) return '';
    if (text.length <= previewLength) return text;
    return '${text.substring(0, previewLength)}…';
  }

  /// 预览的长度上限。两行中文大约 45 个字，留到 70 是为了让列表里的省略号
  /// 只出现在真的长文上，而短公告整段显示得下。
  static const int previewLength = 70;
}

/// 列表页解析出来的一页。
class ShuAnnouncementPage {
  const ShuAnnouncementPage({required this.items, this.nextPage});

  final List<ShuAnnouncementListItem> items;

  /// 下一页的地址；已经是最后一页时为 null。
  ///
  /// 取自分页控件里「下页」那个 `<a>` 的 href —— 它是站点自己算出来的，
  /// 比在客户端拼 `tzgg/{n}.htm` 可靠：该站的页码是倒着编的（首页
  /// `tzgg.htm`，第 k 页是 `tzgg/{总页数+1-k}.htm`），而且会随新公告逐条
  /// 平移。
  final Uri? nextPage;
}

/// 拿不到公告时的说法。
///
/// 界面直接把 `toString()` 摆出来（「通知公告加载失败」下面那一行），所以
/// 文案要能当人话说：网络错误、模板变化、后台解析服务停掉，都是这一句带过去
/// 的。
class ShuAnnouncementException implements Exception {
  const ShuAnnouncementException(this.message, {this.statusCode});

  final String message;

  /// HTTP 状态码；不是从响应上失败的时候为 null。
  final int? statusCode;

  @override
  String toString() {
    final code = statusCode;
    return code == null ? message : '$message ($code)';
  }
}
