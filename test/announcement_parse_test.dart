// 解析信息办公告的纯函数。
//
// 站点没有 API，正文与列表都是服务端渲染的 HTML，所以这一层是唯一有可测分支
// 的地方 —— 网络那一半只是取与解码。夹具按 2026-10-05 抓下来的真实页面结构
// 缩写了：`div.only-list1 > ul > li[id^=line_u4]`、分页的 `span.p_next`、
// 详情页的 `span.Head` / `创建时间：` / `div.v_news_content`。

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuvpn/core/announcements/shu_announcement.dart';
import 'package:shuvpn/core/announcements/shu_announcement_client.dart';
import 'package:shuvpn/core/announcements/shu_announcement_parser.dart';
import 'package:shuvpn/core/announcements/shu_announcement_parser_host.dart';

/// 列表页。首页在 `index/tzgg.htm` 下写 `../info/…`，第 k 页在
/// `index/tzgg/30.htm` 下写 `../../info/…` —— 两种相对写法都要能解析。
String _listHtml({required String prefix, required String pager}) =>
    '''
<div class="fr list-right">
  <div class="only-list1">
    <ul>
      <li id="line_u4_0">
        <a href="$prefix/info/1095/6432.htm" target="_blank">关于2026年 上海大学计算机软件及数据类无形资产清查盘点的通知</a><span>2026-09-22</span>
      </li>
      <li id="line_u4_1">
        <a href="$prefix/info/1095/6422.htm" target="_blank">&nbsp;关于启用新版本企业微信的通知&nbsp;</a><span>2026/09/08</span>
      </li>
      <li id="line_u4_2">
        <a href="javascript:void(0)" target="_blank">空链接应当被跳过</a><span>2026-09-01</span>
      </li>
    </ul>
  </div>
  <div class="fanye">$pager</div>
</div>
''';

/// 详情页。
///
/// 署名被裹在日期后面那个 `<font>` 里 —— 站点就是这么排的，而它的
/// `nextElementSibling` 取到的是整段（连「浏览次数」一起），所以夹具必须
/// 照原样写，否则测不出那个坑。
String _detailHtml({String authorCell = '<span>吕露</span>'}) =>
    '''
<div class="content">
  <table><tbody><tr><td align="center">
    <span class="Head" style="font-size:20px;">关于2026年资产清查盘点的通知</span>
  </td></tr>
  <tr valign="middle"><td>
    <span style="font-weight:bold;">创建时间：&nbsp;&nbsp;</span><span>2026/09/22</span>&nbsp;<font face="">
      $authorCell&nbsp;<font face="Times New Roman"><span style="font-weight:bold;">浏览次数：</span></font>
      <span><script>_showDynClicks("wbnews", 1663284523, 6432)</script></span>
    </font>
  </td></tr>
  </tbody></table>
  <div id="vsb_content_100"><div class="v_news_content">
    <div><div>
      <p class="vsbcontent_start">各学院（部门）：</p>
      <p>本次清查盘点截止到 2026年8月31日。&nbsp;请于 11月30日前完成自查。</p>
      <p><img orisrc="../../img/notice.png" src="../../img/notice_small.png" alt="盘点流程"></p>
      <p class="vsbcontent_end" style="text-align: right;">信息化工作办公室</p>
    </div></div>
  </div></div>
  <p><UL style="list-style-type:none;">
    <li>附件【<a href="/system/_content/download.jsp?urltype=news.DownloadAttachUrl&amp;wbfileid=CB68" target="_blank">上海大学计算机软件及数据类无形资产自查表.rar</a>】已下载<span>12</span>次</li>
  </UL></p>
  <p>上一条：<a href="6142.htm">关于上海大学无线网络紧急升级的通知</a></p>
</div>
''';

/// 带链接与表格的正文。
///
/// 链接写在**句子中间**（站点就是这么排的），表格带一个 `colspan` 的合并行 ——
/// 那是「每行列数一致」这条渲染要求在真实数据里的样子。
const String _richBody = '''
<html><body>
  <div class="v_news_content">
    <p>如需申请本校邮箱，请点击这里：<a href="https://newsso.shu.edu.cn/oauth2/mailRegister">上海大学邮箱申请</a>。</p>
    <p>校内通知见 <a href="6192.htm">另一条通知</a>，或 <a href="javascript:void(0)">点这里</a>。</p>
    <p>按下面这张表自查：</p>
    <table border="1">
      <tbody>
        <tr class="firstRow"><td>模块</td><td>主要内容</td></tr>
        <tr><td>信创入门</td><td>什么是信创？</td></tr>
        <tr><td colspan="2">合并的一行</td></tr>
      </tbody>
    </table>
    <p>表格之后还有一句。</p>
  </div>
</body></html>
''';

/// 表格里再套一张排版表（Word 贴出来的表常常如此），其中一格还带个链接。
const String _nestedTableBody = '''
<html><body>
  <div class="v_news_content">
    <table>
      <tbody>
        <tr class="firstRow"><td>外层表头</td><td>第二列</td></tr>
        <tr>
          <td><a href="https://www.shu.edu.cn/">链接</a></td>
          <td><table><tbody><tr><td>内层排版表</td></tr></tbody></table></td>
        </tr>
      </tbody>
    </table>
  </div>
</body></html>
''';

void main() {
  group('parseAnnouncementList', () {
    test('reads titles, dates and absolute urls from the first page', () {
      final page = parseAnnouncementList(
        _listHtml(prefix: '..', pager: _pager()),
        baseUri: Uri.parse('https://newits.shu.edu.cn/index/tzgg.htm'),
      );

      // 第三条的 href 是 javascript:，标题再正常也不该进列表。
      expect(page.items, hasLength(2));
      final first = page.items.first;
      expect(first.title, '关于2026年 上海大学计算机软件及数据类无形资产清查盘点的通知');
      expect(
        first.url.toString(),
        'https://newits.shu.edu.cn/info/1095/6432.htm',
      );
      expect(first.dateText, '2026-09-22');
      expect(first.publishedAt, DateTime(2026, 9, 22));
    });

    test('resolves the deeper relative prefix used by a numbered page', () {
      final page = parseAnnouncementList(
        _listHtml(prefix: '../..', pager: _pager()),
        baseUri: Uri.parse('https://newits.shu.edu.cn/index/tzgg/30.htm'),
      );

      expect(
        page.items.first.url.toString(),
        'https://newits.shu.edu.cn/info/1095/6432.htm',
      );
    });

    test('folds nbsp and trims the title', () {
      final page = parseAnnouncementList(
        _listHtml(prefix: '..', pager: _pager()),
        baseUri: Uri.parse('https://newits.shu.edu.cn/index/tzgg.htm'),
      );

      expect(page.items[1].title, '关于启用新版本企业微信的通知');
      expect(page.items[1].publishedAt, DateTime(2026, 9, 8));
    });

    test('follows the next-page link the site itself renders', () {
      // 首页的地址是 `index/tzgg.htm`，站点在分页里写的也是相对 `index/` 的
      // 路径（`tzgg/31.htm`）；换成自己拼页码就会把这层算错。
      final page = parseAnnouncementList(
        _listHtml(
          prefix: '..',
          pager: _pager(next: 'tzgg/31.htm'),
        ),
        baseUri: Uri.parse('https://newits.shu.edu.cn/index/tzgg.htm'),
      );

      expect(
        page.nextPage.toString(),
        'https://newits.shu.edu.cn/index/tzgg/31.htm',
      );
    });

    test('follows the pagers own href from a numbered page', () {
      // 第 k 页在 `index/tzgg/30.htm` 下，「下页」写的是同目录的 `29.htm`。
      final page = parseAnnouncementList(
        _listHtml(
          prefix: '../..',
          pager: _pager(next: '29.htm'),
        ),
        baseUri: Uri.parse('https://newits.shu.edu.cn/index/tzgg/30.htm'),
      );

      expect(
        page.nextPage.toString(),
        'https://newits.shu.edu.cn/index/tzgg/29.htm',
      );
    });

    test('has no next page when the pager is on its last one', () {
      // 到底时站点把 `p_next` 换成 `p_next_d`，里面的 `<a>` 一起消失。
      final html = _listHtml(
        prefix: '..',
        pager:
            '<div class="pb_sys_common"><span class="p_no_d">32</span>'
            '<span class="p_next_d p_fun_d">下页</span></div>',
      );
      final page = parseAnnouncementList(
        html,
        baseUri: Uri.parse('https://newits.shu.edu.cn/index/tzgg/1.htm'),
      );

      expect(page.nextPage, isNull);
      expect(page.items, isNotEmpty);
    });

    test(
      'returns an empty page instead of throwing when the template moves',
      () {
        final page = parseAnnouncementList(
          '<html><body><p>维护中</p></body></html>',
          baseUri: Uri.parse('https://newits.shu.edu.cn/index/tzgg.htm'),
        );

        expect(page.items, isEmpty);
        expect(page.nextPage, isNull);
      },
    );
  });

  group('parseAnnouncementDetail', () {
    final url = Uri.parse('https://newits.shu.edu.cn/info/1095/6432.htm');

    test('reads the title, date and author', () {
      final detail = parseAnnouncementDetail(_detailHtml(), url: url);

      expect(detail.title, '关于2026年资产清查盘点的通知');
      expect(detail.dateText, '2026/09/22');
      expect(detail.publishedAt, DateTime(2026, 9, 22));
      expect(detail.author, '吕露');
    });

    test('keeps paragraphs and images in document order', () {
      final detail = parseAnnouncementDetail(_detailHtml(), url: url);

      // 段落 → 图片 → 段落：图片自己占一个 `<p>`，不该在它前后留下空的文字块。
      expect(
        detail.blocks.whereType<ShuAnnouncementText>().map((b) => b.text),
        ['各学院（部门）：', '本次清查盘点截止到 2026年8月31日。 请于 11月30日前完成自查。', '信息化工作办公室'],
      );
      final image = detail.blocks.whereType<ShuAnnouncementImage>().single;
      // `orisrc` 是原图，`src` 是缩略图。
      expect(image.url, 'https://newits.shu.edu.cn/img/notice.png');
      expect(image.alt, '盘点流程');
      expect(
        detail.blocks.indexOf(image),
        detail.blocks.indexWhere((b) => b is ShuAnnouncementImage),
      );
    });

    test('lists attachments with their download urls', () {
      final detail = parseAnnouncementDetail(_detailHtml(), url: url);

      final attachment = detail.blocks
          .whereType<ShuAnnouncementAttachment>()
          .single;
      expect(attachment.name, '上海大学计算机软件及数据类无形资产自查表.rar');
      expect(
        attachment.url.toString(),
        startsWith('https://newits.shu.edu.cn/system/_content/download.jsp'),
      );
      // 附件排在正文之后。
      expect(detail.blocks.last, isA<ShuAnnouncementAttachment>());
    });

    test('does not mistake the click counter for the author', () {
      // 署名一格是空的时，往后取到的是「浏览 次数：」那一格。
      final detail = parseAnnouncementDetail(
        _detailHtml(authorCell: ''),
        url: url,
      );

      expect(detail.author, isEmpty);
    });

    test('falls back to the list title when the body has no heading', () {
      final detail = parseAnnouncementDetail(
        '<html><body><div class="v_news_content"><p>正文</p></div></body></html>',
        url: url,
        fallbackTitle: '列表里的标题',
        fallbackDateText: '2026-09-22',
      );

      expect(detail.title, '列表里的标题');
      expect(detail.dateText, '2026-09-22');
      expect(detail.publishedAt, DateTime(2026, 9, 22));
      expect(detail.hasContent, isTrue);
    });

    test('reports no content rather than trusting a missing body', () {
      final detail = parseAnnouncementDetail(
        '<html><body><span class="Head">只有标题</span></body></html>',
        url: url,
      );

      expect(detail.title, '只有标题');
      expect(detail.hasContent, isFalse);
    });
  });

  group('正文里的链接', () {
    final url = Uri.parse('https://newits.shu.edu.cn/info/1095/6432.htm');

    test('keeps the sentence around the link and resolves its address', () {
      final detail = parseAnnouncementDetail(_richBody, url: url);

      final paragraph = detail.blocks.whereType<ShuAnnouncementText>().first;
      // 站点把入口写在句子中间：链接前后那两截文字都属于同一段。
      expect(paragraph.plainText, '如需申请本校邮箱，请点击这里：上海大学邮箱申请。');
      expect(paragraph.inlines.map((inline) => inline.text).toList(), <String>[
        '如需申请本校邮箱，请点击这里：',
        '上海大学邮箱申请',
        '。',
      ]);
      expect(paragraph.inlines[1].url.toString(), startsWith('https://newsso'));
      expect(paragraph.inlines[0].url, isNull);
    });

    test('resolves a relative address against the article itself', () {
      final detail = parseAnnouncementDetail(_richBody, url: url);

      final link = detail.blocks
          .whereType<ShuAnnouncementText>()
          .expand((block) => block.inlines)
          .firstWhere((inline) => inline.text == '另一条通知');

      expect(
        link.url.toString(),
        'https://newits.shu.edu.cn/info/1095/6192.htm',
      );
    });

    test('keeps an unusable href as plain text', () {
      final detail = parseAnnouncementDetail(_richBody, url: url);

      final dead = detail.blocks
          .whereType<ShuAnnouncementText>()
          .expand((block) => block.inlines)
          .firstWhere((inline) => inline.text == '点这里');

      // `javascript:void(0)` 不是地址，但那些字还是正文的一部分。
      expect(dead.url, isNull);
      expect(dead.isLink, isFalse);
    });
  });

  group('正文里的表格', () {
    final url = Uri.parse('https://newits.shu.edu.cn/info/1095/6432.htm');

    test('keeps the table where it was, not at the end', () {
      final detail = parseAnnouncementDetail(_richBody, url: url);

      expect(detail.blocks.map((block) => block.runtimeType).toList(), <Type>[
        ShuAnnouncementText,
        ShuAnnouncementText,
        ShuAnnouncementText,
        ShuAnnouncementTable,
        ShuAnnouncementText,
      ]);
    });

    test('reads the header row and the cells', () {
      final detail = parseAnnouncementDetail(_richBody, url: url);

      final table = detail.blocks.whereType<ShuAnnouncementTable>().single;
      // 站点用 `<tr class="firstRow">` 标表头，那边是 `<td>` 不是 `<th>`。
      expect(table.hasHeaderRow, isTrue);
      expect(table.rows, hasLength(3));
      expect(table.rows.first.map((cell) => cell.plainText).toList(), <String>[
        '模块',
        '主要内容',
      ]);
      expect(table.rows[1].map((cell) => cell.plainText).toList(), <String>[
        '信创入门',
        '什么是信创？',
      ]);
    });

    test('pads a merged cell so every row has the same column count', () {
      final detail = parseAnnouncementDetail(_richBody, url: url);

      final table = detail.blocks.whereType<ShuAnnouncementTable>().single;
      // `colspan="2"` 那一行少一个格子；不补齐的话 `Table` 会抛断言。
      expect(table.rows.map((row) => row.length).toSet(), <int>{2});
      expect(table.rows.last.first.plainText, '合并的一行');
      expect(table.rows.last.last.plainText, isEmpty);
    });

    test('ignores the rows of a table nested inside a cell', () {
      final detail = parseAnnouncementDetail(_nestedTableBody, url: url);

      final table = detail.blocks.whereType<ShuAnnouncementTable>().single;
      // 内层那张排版表的行也算进来的话，这里会是 4 行。
      expect(table.rows, hasLength(2));
      expect(table.rows.first.first.plainText, '外层表头');
    });

    test('keeps a link inside a cell', () {
      final detail = parseAnnouncementDetail(_nestedTableBody, url: url);

      final table = detail.blocks.whereType<ShuAnnouncementTable>().single;
      final link = table.rows[1].first.inlines.single;
      expect(link.text, '链接');
      expect(link.url.toString(), 'https://www.shu.edu.cn/');
    });
  });

  group('列表里的两行预览', () {
    final url = Uri.parse('https://newits.shu.edu.cn/info/1095/6432.htm');

    test('joins the leading paragraphs and skips images', () {
      final detail = parseAnnouncementDetail(_richBody, url: url);

      expect(detail.preview, startsWith('如需申请本校邮箱，请点击这里：上海大学邮箱申请。'));
    });

    test('cuts a long body and marks the cut', () {
      final detail = ShuAnnouncementDetail(
        title: '标题',
        url: url,
        blocks: <ShuAnnouncementBlock>[ShuAnnouncementText('字' * 200)],
      );

      expect(detail.preview.length, ShuAnnouncementDetail.previewLength + 1);
      expect(detail.preview, endsWith('…'));
    });

    test('is empty when the body has no text at all', () {
      final detail = ShuAnnouncementDetail(
        title: '标题',
        url: url,
        blocks: const <ShuAnnouncementBlock>[
          ShuAnnouncementImage('https://newits.shu.edu.cn/img/notice.png'),
        ],
      );

      expect(detail.preview, isEmpty);
    });
  });

  group('parseShuAnnouncementDate', () {
    test('accepts the separators the site actually uses', () {
      expect(parseShuAnnouncementDate('2026-09-22'), DateTime(2026, 9, 22));
      expect(parseShuAnnouncementDate('2026/09/22'), DateTime(2026, 9, 22));
      expect(parseShuAnnouncementDate('2026.9.2'), DateTime(2026, 9, 2));
    });

    test('returns null for anything else', () {
      expect(parseShuAnnouncementDate(''), isNull);
      expect(parseShuAnnouncementDate('近期'), isNull);
    });
  });

  group('只取本站的公告地址', () {
    test('accepts the notice site and rejects everything else', () {
      expect(
        isShuAnnouncementUrl(
          Uri.parse('https://newits.shu.edu.cn/info/1095/6432.htm'),
        ),
        isTrue,
      );
      expect(
        isShuAnnouncementUrl(Uri.parse('http://newits.shu.edu.cn/x.htm')),
        isTrue,
        reason: '协议不参与判断，站点上是 http 也取',
      );

      expect(
        isShuAnnouncementUrl(Uri.parse('https://www.shu.edu.cn/')),
        isFalse,
      );
      // CNAME 的落点是 DNS 的事：请求里的主机名仍然是 newits。
      expect(
        isShuAnnouncementUrl(Uri.parse('https://web10.shu.edu.cn/')),
        isFalse,
      );
      // 不是子域通配 —— 「以它结尾」会把这两个放进来。
      expect(
        isShuAnnouncementUrl(Uri.parse('https://blog.newits.shu.edu.cn/')),
        isFalse,
      );
      expect(
        isShuAnnouncementUrl(
          Uri.parse('https://newits.shu.edu.cn.example.com/info/1.htm'),
        ),
        isFalse,
      );
      expect(isShuAnnouncementUrl(Uri.parse('file:///etc/hosts')), isFalse);
    });
  });

  group('后台解析 isolate', () {
    final url = Uri.parse('https://newits.shu.edu.cn/info/1095/6432.htm');

    test('parses a list page and a body away from the interface', () async {
      final host = ShuAnnouncementParserHost();
      addTearDown(host.close);

      final page = await host.parseList(
        _bytes(_listHtml(prefix: '..', pager: _pager())),
        baseUri: Uri.parse('https://newits.shu.edu.cn/index/tzgg.htm'),
      );
      expect(page.items.map((item) => item.title), contains('关于启用新版本企业微信的通知'));
      expect(page.nextPage, isNull);

      final detail = await host.parseDetail(_bytes(_detailHtml()), url: url);
      expect(detail.title, '关于2026年资产清查盘点的通知');
      expect(detail.author, '吕露');
      // 图片、链接、表格都要原样过 isolate（对象树是拷过来的，不是序列化的）。
      expect(detail.blocks.whereType<ShuAnnouncementImage>(), hasLength(1));
      expect(
        detail.blocks.whereType<ShuAnnouncementAttachment>(),
        hasLength(1),
      );
    });

    test('answers every queued request', () async {
      final host = ShuAnnouncementParserHost();
      addTearDown(host.close);
      final body = _bytes(_richBody);

      // 十二条一起排进去：一条 isolate 串行处理，回来的是十二条各自的结果。
      final results = await Future.wait(<Future<ShuAnnouncementDetail>>[
        for (var index = 0; index < 12; index++)
          host.parseDetail(
            body,
            url: Uri.parse('https://newits.shu.edu.cn/info/1095/$index.htm'),
          ),
      ]);

      expect(results, hasLength(12));
      expect(results.every((detail) => detail.blocks.isNotEmpty), isTrue);
      expect(results.first.preview, startsWith('如需申请本校邮箱'));
    });

    test('refuses work after close', () async {
      final host = ShuAnnouncementParserHost()..close();

      await expectLater(
        host.parseList(
          _bytes(_listHtml(prefix: '..', pager: _pager())),
          baseUri: Uri.parse('https://newits.shu.edu.cn/index/tzgg.htm'),
        ),
        throwsA(isA<ShuAnnouncementException>()),
      );
    });
  });
}

/// 响应体交给客户端时的样子：拿到的是字节，解码是后台那一侧的事。
Uint8List _bytes(String html) => Uint8List.fromList(utf8.encode(html));

String _pager({String? next}) {
  final link = next == null
      ? '<span class="p_next_d p_fun_d">下页</span>'
      : '<span class="p_next p_fun"><a href="$next">下页</a></span>';
  return '<div class="pb_sys_common"><span class="p_t">共314条</span>'
      '<span class="p_no_d">1</span>$link</div>';
}
