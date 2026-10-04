import 'dart:math' as math;

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import 'shu_announcement.dart';

/// 列表页里每一项的容器。
///
/// 站点是 VSB CMS，模板把列表放在 `div.only-list1 > ul` 里。两层都试是故意的：
/// 换模板时先丢的是这层壳，而 `li[id^=line_u4]` 是模板给每条记录的稳定 id。
const String _listRootSelector = '.only-list1';
const String _listItemSelector = 'li[id^=line_u4]';

/// 解析公告列表页。
///
/// [baseUri] **必须是这一页自己的地址**：同一份模板在 `index/tzgg.htm` 里写
/// `../info/…`、在 `index/tzgg/30.htm` 里写 `../../info/…`，两者相差一层。
/// 用错基地址会得到 404 的链接，而列表本身看起来完全正常。
ShuAnnouncementPage parseAnnouncementList(String html, {required Uri baseUri}) {
  final document = html_parser.parse(html);
  final root = document.querySelector(_listRootSelector) ?? document;
  final items = <ShuAnnouncementListItem>[];
  for (final node in root.querySelectorAll(_listItemSelector)) {
    final anchor = node.querySelector('a');
    final title = _cleanText(anchor?.text);
    final url = _resolveUri(baseUri, anchor?.attributes['href']);
    if (title.isEmpty || url == null) continue;
    final dateText = _cleanText(node.querySelector('span')?.text);
    items.add(
      ShuAnnouncementListItem(
        title: title,
        url: url,
        dateText: dateText,
        publishedAt: parseShuAnnouncementDate(dateText),
      ),
    );
  }
  return ShuAnnouncementPage(
    items: items,
    nextPage: _parseNextPage(document, baseUri),
  );
}

/// 解析一篇公告的正文。
///
/// [title] / [dateText] 是列表页已经拿到的那两个值：详情页偶尔取不到标题
/// （模板差异）时用它兜底，比显示空白强。
ShuAnnouncementDetail parseAnnouncementDetail(
  String html, {
  required Uri url,
  String fallbackTitle = '',
  String fallbackDateText = '',
}) {
  final document = html_parser.parse(html);
  final title = _firstNonEmpty(
    document.querySelectorAll('span.Head').map((node) => node.text),
  );
  final contentRoot = document.querySelector('.v_news_content');
  final dateText = _parseDateText(document) ?? fallbackDateText;
  return ShuAnnouncementDetail(
    title: title.isEmpty ? fallbackTitle : title,
    url: url,
    dateText: dateText,
    publishedAt: parseShuAnnouncementDate(dateText),
    author: _parseAuthor(document),
    blocks: contentRoot == null
        ? const <ShuAnnouncementBlock>[]
        : _parseBlocks(contentRoot, baseUri: url, attachmentsIn: document),
  );
}

/// 把正文拆成有序的内容块。
///
/// [attachmentsIn] 与 [root] 分开传：附件挂在**正文容器之外**（VSB 模板把
/// `<ul>` 附件清单排在 `.v_news_content` 的兄弟位置），在正文里查是查不到的。
List<ShuAnnouncementBlock> _parseBlocks(
  dom.Element root, {
  required Uri baseUri,
  required dom.Document attachmentsIn,
}) {
  final blocks = <ShuAnnouncementBlock>[];
  _collectBlocks(root, blocks, baseUri: baseUri);
  if (blocks.isEmpty) {
    // 正文不是块级标签拼的（整篇只有一串裸文字）时至少保住那一段。
    final text = _cleanText(root.text);
    if (text.isNotEmpty) blocks.add(ShuAnnouncementText(text));
  }
  blocks.addAll(_parseAttachments(attachmentsIn, baseUri: baseUri));
  return blocks;
}

/// 会自己占一段的标签。
///
/// 一个元素里只要有它们中的一个，就说明它是**容器**，要接着往里走；没有就说明
/// 它自己是一段文字。用「有没有块级孩子」来判断而不是按标签名枚举，是因为正文
/// 是 Word 转出来的嵌套（`<div><div><p>…</p></div></div>`，段落还可能是
/// `<li>`），枚举必然会漏掉某一层。
const Set<String> _blockTags = <String>{
  'p',
  'div',
  'table',
  'ul',
  'ol',
  'li',
  'dl',
  'dt',
  'dd',
  'tr',
  'td',
  'th',
  'tbody',
  'thead',
  'tfoot',
  'section',
  'article',
  'blockquote',
  'pre',
  'hr',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
};

/// 内容不属于正文的标签。
const Set<String> _ignoredTags = <String>{
  'script',
  'style',
  'noscript',
  'iframe',
  'meta',
  'link',
};

/// 按**文档顺序**把正文容器摊成内容块。
///
/// 走节点顺序而不是「先查所有 `<p>`」：表格、图片、列表与段落混在一起，只有按
/// 顺序走才不会把表格挪到文章末尾去 —— 而表格在原文里的位置正是它在读法上的
/// 位置（「按下面这张表自查」）。
void _collectBlocks(
  dom.Element container,
  List<ShuAnnouncementBlock> blocks, {
  required Uri baseUri,
}) {
  for (final node in container.nodes) {
    if (node is dom.Text) {
      final text = _cleanText(node.text);
      if (text.isNotEmpty) blocks.add(ShuAnnouncementText(text));
      continue;
    }
    if (node is! dom.Element) continue;
    final name = node.localName;
    if (_ignoredTags.contains(name) || name == 'hr') continue;
    if (name == 'img') {
      _addImage(blocks, node, baseUri);
      continue;
    }
    if (name == 'table') {
      final table = _parseTable(node, baseUri);
      if (table != null) blocks.add(table);
      continue;
    }
    if (_hasBlockChild(node)) {
      _collectBlocks(node, blocks, baseUri: baseUri);
    } else {
      _emitInline(blocks, node, baseUri: baseUri);
    }
  }
}

bool _hasBlockChild(dom.Element element) =>
    element.children.any((child) => _blockTags.contains(child.localName));

/// 把一个「自己就是一段文字」的元素摊成文字块与图片块，**保持文档顺序**。
///
/// 图片会把前面的文字先收成一个块再自己成块：站点上图片自己占一个 `<p>`，
/// 而混排（`文字<img>文字`）时顺序也只能这么保。
void _emitInline(
  List<ShuAnnouncementBlock> blocks,
  dom.Element element, {
  required Uri baseUri,
}) {
  final inlines = <ShuAnnouncementInline>[];

  void flush() {
    _trimEdges(inlines);
    if (inlines.isEmpty) return;
    // 没有链接的段落仍按纯文字块发出去：`SelectableText` 那条路只认文字，
    // 而文档里绝大多数段落都是它。
    blocks.add(
      inlines.any((inline) => inline.isLink)
          ? ShuAnnouncementText.rich(List<ShuAnnouncementInline>.of(inlines))
          : ShuAnnouncementText(inlines.map((inline) => inline.text).join()),
    );
    inlines.clear();
  }

  void visit(dom.Node node) {
    if (node is dom.Text) {
      final text = _normalizeInline(node.text);
      if (text.isNotEmpty) inlines.add(ShuAnnouncementInline(text));
      return;
    }
    if (node is! dom.Element) return;
    final name = node.localName;
    if (_ignoredTags.contains(name) || name == 'hr') return;
    if (name == 'img') {
      flush();
      _addImage(blocks, node, baseUri);
      return;
    }
    if (name == 'table') {
      flush();
      final table = _parseTable(node, baseUri);
      if (table != null) blocks.add(table);
      return;
    }
    // 裹着图片的链接按普通容器走：图进全屏看图那条路，链接地址在这里没有用。
    if (name == 'a' && node.querySelector('img') == null) {
      inlines.add(
        ShuAnnouncementInline(
          _normalizeInline(node.text),
          url: _resolveUri(baseUri, node.attributes['href']),
        ),
      );
      return;
    }
    for (final child in node.nodes) {
      visit(child);
    }
  }

  // 从元素**自身**开始走而不是从它的孩子开始：`<td><a href="…">链接</a></td>`
  // 这种元素自己就是链接，从孩子开始就把 href 丢在这一层了。
  visit(element);
  flush();
}

void _addImage(
  List<ShuAnnouncementBlock> blocks,
  dom.Element image,
  Uri baseUri,
) {
  // `orisrc` 是站点给的原图，`src` 是缩略图。
  final source =
      image.attributes['orisrc'] ??
      image.attributes['src'] ??
      image.attributes['vurl'] ??
      '';
  final uri = _resolveUri(baseUri, source);
  if (uri == null) return;
  blocks.add(
    ShuAnnouncementImage(
      uri.toString(),
      alt: _cleanText(image.attributes['alt']),
    ),
  );
}

/// 折叠行内文字里的空白但**不裁边** —— 片段之间的那个空格是有意义的
/// （`<span>a</span> <span>b</span>` 里它是唯一的分隔），裁边留给 [_trimEdges]。
String _normalizeInline(String? value) =>
    (value ?? '').replaceAll('\u00a0', ' ').replaceAll(RegExp(r'\s+'), ' ');

/// 去掉段落首尾的空白。站点用 `&nbsp;` 排版，段首段尾常带一串空格；段落中间
/// 的空白留着。
void _trimEdges(List<ShuAnnouncementInline> inlines) {
  while (inlines.isNotEmpty) {
    final first = inlines.first;
    final trimmed = first.text.replaceFirst(_leadingSpace, '');
    if (trimmed.isEmpty) {
      inlines.removeAt(0);
      continue;
    }
    if (trimmed != first.text) {
      inlines[0] = ShuAnnouncementInline(trimmed, url: first.url);
    }
    break;
  }
  while (inlines.isNotEmpty) {
    final last = inlines.last;
    final trimmed = last.text.replaceFirst(_trailingSpace, '');
    if (trimmed.isEmpty) {
      inlines.removeLast();
      continue;
    }
    if (trimmed != last.text) {
      inlines[inlines.length - 1] = ShuAnnouncementInline(
        trimmed,
        url: last.url,
      );
    }
    break;
  }
}

final RegExp _leadingSpace = RegExp(r'^\s+');
final RegExp _trailingSpace = RegExp(r'\s+$');

/// 解析正文里的一张表。
///
/// 只收**最外层**表格的行：Word 贴出来的表里可能再嵌一层排版表，把内层的行也
/// 算进来会得到一张错位的网格。
ShuAnnouncementTable? _parseTable(dom.Element table, Uri baseUri) {
  final rows = <List<ShuAnnouncementTableCell>>[];
  var hasHeaderRow = false;

  for (final row in table.querySelectorAll('tr')) {
    if (_nearestTable(row) != table) continue;
    final cells = <ShuAnnouncementTableCell>[];
    for (final cell in row.children) {
      final name = cell.localName;
      if (name != 'td' && name != 'th') continue;
      cells.add(ShuAnnouncementTableCell(_cellInlines(cell, baseUri)));
      // 合并列补成空格子：`Table` 要求每行列数一致。
      final span = int.tryParse(cell.attributes['colspan'] ?? '') ?? 1;
      for (var extra = 1; extra < span; extra++) {
        cells.add(ShuAnnouncementTableCell.empty);
      }
      if (name == 'th') hasHeaderRow = true;
    }
    if (cells.isEmpty) continue;
    if (rows.isEmpty && _isHeaderRow(row)) hasHeaderRow = true;
    rows.add(cells);
  }

  if (rows.isEmpty) return null;
  final columns = rows.map((row) => row.length).reduce(math.max);
  for (final row in rows) {
    while (row.length < columns) {
      row.add(ShuAnnouncementTableCell.empty);
    }
  }
  return ShuAnnouncementTable(rows: rows, hasHeaderRow: hasHeaderRow);
}

/// 站点用 `<tr class="firstRow">` 标出表头 —— 那是 Word 转出来的标记，但它是
/// 这一行是表头的唯一信号（那些格子都是 `<td>`）。
bool _isHeaderRow(dom.Element row) =>
    (row.attributes['class'] ?? '').split(RegExp(r'\s+')).contains('firstRow');

/// [node] 所属的那张表（最近的一层）。
dom.Element? _nearestTable(dom.Element node) {
  for (dom.Node? parent = node.parent; parent != null; parent = parent.parent) {
    if (parent is dom.Element && parent.localName == 'table') return parent;
  }
  return null;
}

/// 一个格子里的文字。格子里的段落与链接都收成行内片段，表格里的图片丢掉 ——
/// 格子按文字排版，图片塞进去会把这一列的宽度全部吃掉。
List<ShuAnnouncementInline> _cellInlines(dom.Element cell, Uri baseUri) {
  final blocks = <ShuAnnouncementBlock>[];
  _collectBlocks(cell, blocks, baseUri: baseUri);
  final inlines = <ShuAnnouncementInline>[];
  for (final block in blocks) {
    if (block is! ShuAnnouncementText) continue;
    // 一个格子里的多个 `<p>` 连成一行，中间留一个空格。
    if (inlines.isNotEmpty) inlines.add(const ShuAnnouncementInline(' '));
    inlines.addAll(
      block.inlines.isEmpty
          ? <ShuAnnouncementInline>[ShuAnnouncementInline(block.text)]
          : block.inlines,
    );
  }
  return inlines;
}

/// 正文末尾的附件下载项。
///
/// 附件在模板里是 `<li>附件【<a href="/system/_content/download.jsp?…">名字</a>】</li>`，
/// 所以名字取 `<a>` 的文字，地址取它的 href。
List<ShuAnnouncementBlock> _parseAttachments(
  dom.Document document, {
  required Uri baseUri,
}) {
  final attachments = <ShuAnnouncementBlock>[];
  for (final anchor in document.querySelectorAll('a')) {
    final uri = _resolveUri(baseUri, anchor.attributes['href']);
    if (uri == null || !uri.path.contains('download.jsp')) continue;
    final name = _cleanText(anchor.text);
    if (name.isEmpty) continue;
    attachments.add(ShuAnnouncementAttachment(name, uri));
  }
  return attachments;
}

/// 「下页」那个链接。到底时站点把 `span.p_next` 换成 `span.p_next_d`（没有
/// 里面的 `<a>`），所以查不到 `<a>` 就是最后一页 —— 不需要自己比页码。
Uri? _parseNextPage(dom.Document document, Uri baseUri) {
  final anchor = document.querySelector('span.p_next > a');
  return _resolveUri(baseUri, anchor?.attributes['href']);
}

/// `创建时间：2025/09/22` 后面那个日期。
String? _parseDateText(dom.Document document) {
  for (final span in document.querySelectorAll('span')) {
    final text = _cleanText(span.text);
    if (text.startsWith(_createdAtLabel)) {
      final value = text.substring(_createdAtLabel.length).trim();
      if (value.isNotEmpty) return value;
      // 标签与值分在两个 span 里时，值在下一个兄弟节点上。
      final sibling = span.nextElementSibling;
      final next = _cleanText(sibling?.text);
      if (next.isNotEmpty) return next;
    }
  }
  return null;
}

/// 创建时间标签。模板里写的是 `创建时间：`，冒号是全角。
const String _createdAtLabel = '创建时间：';

/// 署名。它紧跟在日期后面，是同一个 `<td>` 里最后一个非标签文字。
///
/// 这一栏在站点上就叫「作者」，模板没有给它任何 class 或 id，而且它被裹在日期
/// 后面那个 `<font>` 里 —— 所以不能取日期的 `nextElementSibling`（那拿到的是
/// `<font>` 整段，连「浏览次数」一起）。按文档顺序往后找第一个不像字段名的
/// span，是这一栏唯一稳定的取法。
String _parseAuthor(dom.Document document) {
  final dateText = _parseDateText(document);
  if (dateText == null) return '';
  final spans = document.querySelectorAll('span');
  final dateIndex = spans.indexWhere(
    (span) => _cleanText(span.text) == dateText,
  );
  if (dateIndex < 0) return '';
  for (final span in spans.skip(dateIndex + 1)) {
    final text = _cleanText(span.text);
    if (text.isEmpty) continue;
    // `浏览次数：` 是这一格的结尾 —— 走到它就说明作者本来就是空的，
    // 再往后找只会拾到页面下方别的 span。
    if (text.contains('次数')) return '';
    return text;
  }
  return '';
}

String _firstNonEmpty(Iterable<String> values) {
  for (final value in values) {
    final text = _cleanText(value);
    if (text.isNotEmpty) return text;
  }
  return '';
}

/// 把站点上的日期文本解析成日期，认 `2025-09-22` 与 `2025/09/22` 两种写法。
DateTime? parseShuAnnouncementDate(String value) {
  final match = RegExp(r'(\d{4})[.\-/年](\d{1,2})[.\-/月](\d{1,2})')
      .firstMatch(value);
  if (match == null) return null;
  final year = int.tryParse(match.group(1)!);
  final month = int.tryParse(match.group(2)!);
  final day = int.tryParse(match.group(3)!);
  if (year == null || month == null || day == null) return null;
  return DateTime(year, month, day);
}

/// 相对地址按 [baseUri] 展开；空值与 `javascript:` 之类返回 null。
Uri? _resolveUri(Uri baseUri, String? value) {
  final trimmed = (value ?? '').trim();
  if (trimmed.isEmpty || trimmed.startsWith('javascript:')) return null;
  return baseUri.resolve(trimmed);
}

/// 折叠空白。站点用 `&nbsp;` 排版，直接显示会带上不换行的空格。
String _cleanText(String? value) {
  return (value ?? '')
      .replaceAll('\u00a0', ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}
