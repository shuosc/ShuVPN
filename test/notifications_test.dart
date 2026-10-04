// 服务页两个入口、通知页的公告列表与详情。
//
// 全部走替身通道（`announcement_stub.dart`）：这些用例验的是**界面的形状与
// 行为**（点进去是什么、滑到底会不会续、失败能不能重试），解析与取数是另外
// 两个文件的事（`announcement_parse_test.dart`）。

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuvpn/app/app.dart';
import 'package:shuvpn/core/announcements/shu_announcement.dart';
import 'package:shuvpn/core/settings/settings_store.dart';
import 'package:shuvpn/features/notifications/announcement_detail_page.dart';
import 'package:shuvpn/features/notifications/notifications_page.dart';
import 'package:shuvpn/features/services/coming_soon_page.dart';
import 'package:shuvpn/shell/floating_dock.dart';
import 'package:shuvpn/widgets/shu_surfaces.dart';

import 'announcement_stub.dart';
import 'shu_update_stub.dart';

/// 一台高瘦手机（逻辑 360×1800）：下面的用例多半在断言「列表里有什么」，
/// 高一点可以让一整页都建出来，不必为每条断言编排滚动。
const Size _tallPhone = Size(720, 3600);

/// 一台矮手机（逻辑 360×360）。**续页的用例必须用它**：列表短于视口时根本
/// 滚不动，也就不会有滚动通知，预取那条路一次都跑不到。
const Size _shortPhone = Size(720, 720);

Future<void> _pumpApp(
  WidgetTester tester, {
  required StubShuAnnouncementClient announcements,
  Size physical = _tallPhone,
}) async {
  tester.view.physicalSize = physical;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);

  SharedPreferences.setMockInitialValues(<String, Object>{});
  final settings = await SettingsStore.load();
  settings.welcomeCompleted = true;
  await tester.pumpWidget(
    ShuVpnApp(
      settings: settings,
      updateClient: StubShuUpdateClient(),
      announcementClient: announcements,
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openTab(WidgetTester tester, String label) async {
  await tester.tap(
    find.descendant(of: find.byType(FloatingDock), matching: find.text(label)),
  );
  await tester.pumpAndSettle();
}

/// 从服务页顶栏的通知入口进通知页。
///
/// 走的是真入口（一级页顶栏左槽），而不是把路由地址直接推上去 —— 这样
/// 「通知挂在哪儿」这件事也一起被测到了。
Future<void> _openNotificationsRow(WidgetTester tester) async {
  await _openTab(tester, '服务');
  await tester.tap(find.byTooltip('通知'));
  await tester.pumpAndSettle();
}

Future<void> _openRow(WidgetTester tester, String label) async {
  await tester.tap(
    find.descendant(of: find.byType(ListTile), matching: find.text(label)),
  );
  await tester.pumpAndSettle();
}

/// 滑到底。位移给得比内容长，位置会被夹到 `maxScrollExtent` —— 那正是
/// 预取要的那一态。
Future<void> _scrollToBottom(WidgetTester tester) async {
  await tester.drag(find.byType(Scrollable).first, const Offset(0, -4000));
  await tester.pumpAndSettle();
}

/// 把 `url_launcher` 的通道接过来，返回它被要求打开的地址。
///
/// 测试环境里没有浏览器插件，而这个通道**不会**以 `MissingPluginException`
/// 结束 —— 没人应答就一直挂着。接过来既能看到要打开的是哪个地址，也不会真的
/// 把浏览器叫起来。
List<String> _mockExternalLauncher() {
  final launched = <String>[];
  const channel = MethodChannel('plugins.flutter.io/url_launcher');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(channel, (call) async {
    launched.add((call.arguments as Map<Object?, Object?>)['url']! as String);
    return true;
  });
  addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  return launched;
}

/// 第一页：`count` 条公告 + 一个指向 [next] 的「下页」。
StubShuAnnouncementClient _pagedClient({
  required int count,
  required String next,
  required Map<String, ShuAnnouncementPage> pages,
}) {
  return StubShuAnnouncementClient(
    firstPage: ShuAnnouncementPage(
      items: <ShuAnnouncementListItem>[
        for (var index = 1; index <= count; index++)
          stubAnnouncement('a$index'),
      ],
      nextPage: Uri.parse(next),
    ),
    pages: pages,
  );
}

void main() {
  group('服务页的两个模块', () {
    testWidgets('lists 网络测速 and 图书馆目录', (tester) async {
      await _pumpApp(tester, announcements: StubShuAnnouncementClient());
      await _openTab(tester, '服务');

      expect(find.text('网络测速'), findsOneWidget);
      expect(find.text('图书馆目录'), findsOneWidget);
      // 这一页是目录，不是设置：里面不放开关，也不报任何数值。
      expect(find.byType(SwitchListTile), findsNothing);
    });

    testWidgets('both open a page that says the future version has it', (
      tester,
    ) async {
      await _pumpApp(tester, announcements: StubShuAnnouncementClient());
      await _openTab(tester, '服务');

      for (final entry in <String>['网络测速', '图书馆目录']) {
        await _openRow(tester, entry);

        expect(find.byType(ShuComingSoonPage), findsOneWidget);
        expect(find.text('未来版本提供服务'), findsOneWidget);
        // 占位页只此一句：不写排期，也不留第二行小字。
        expect(find.byType(EmptyState), findsOneWidget);
        expect(find.text(entry), findsWidgets, reason: '顶栏标题就是这一项的名字');

        await tester.tap(find.byTooltip('返回'));
        await tester.pumpAndSettle();
      }
    });
  });

  group('通知页', () {
    testWidgets('renders the list the site returned', (tester) async {
      final client = StubShuAnnouncementClient(
        firstPage: ShuAnnouncementPage(
          items: <ShuAnnouncementListItem>[
            stubAnnouncement('6432', title: '关于资产清查盘点的通知'),
            stubAnnouncement('6422', title: '网络故障紧急通知'),
          ],
        ),
      );
      await _pumpApp(tester, announcements: client);
      await _openNotificationsRow(tester);

      expect(find.text('关于资产清查盘点的通知'), findsOneWidget);
      expect(find.text('网络故障紧急通知'), findsOneWidget);
      expect(find.text('2026-09-22'), findsNWidgets(2));
      expect(find.byType(EmptyState), findsNothing);
      expect(
        find.byKey(NotificationsPage.listEndKey),
        findsOneWidget,
        reason: '没有下一页时要明说到底了',
      );
    });

    testWidgets('shows a two-line preview taken from each body', (
      tester,
    ) async {
      final item = stubAnnouncement('6432');
      final client = StubShuAnnouncementClient(
        firstPage: ShuAnnouncementPage(items: <ShuAnnouncementListItem>[item]),
      );
      await _pumpApp(tester, announcements: client);
      await _openNotificationsRow(tester);

      // 站点那一页没有摘要 —— 这两行是**从正文里摘的**，所以它出现在列表里
      // 这件事本身就说明正文已经被预取回来了。
      expect(find.text('正文第一段。'), findsOneWidget);
      expect(
        tester.widget<Text>(find.text('正文第一段。')).maxLines,
        2,
        reason: '预览就是两行',
      );
      expect(client.requestedDetails, <Uri>[item.url]);
    });

    testWidgets('the source line is one plain line at the top of the list', (
      tester,
    ) async {
      final launched = _mockExternalLauncher();
      final client = StubShuAnnouncementClient(
        firstPage: ShuAnnouncementPage(
          items: <ShuAnnouncementListItem>[stubAnnouncement('6432')],
        ),
      );
      await _pumpApp(tester, announcements: client);
      await _openNotificationsRow(tester);

      expect(find.byKey(NotificationsPage.sourceNoticeKey), findsOneWidget);
      final notice = tester.widget<Text>(
        find.descendant(
          of: find.byKey(NotificationsPage.sourceNoticeKey),
          matching: find.byType(Text),
        ),
      );
      // 一句话，不分段。
      expect(notice.data, '通知来源：上海大学信息化工作办公室 newits.shu.edu.cn');
      expect(notice.maxLines, 1, reason: '一行解决');
      // 注解而不是入口：不下划线，点了也不打开任何东西。
      expect(notice.style?.decoration, isNot(TextDecoration.underline));

      await tester.tap(find.byKey(NotificationsPage.sourceNoticeKey));
      await tester.pumpAndSettle();
      expect(launched, isEmpty);
    });

    testWidgets('the source line scrolls away with the list', (tester) async {
      final client = StubShuAnnouncementClient(
        firstPage: ShuAnnouncementPage(
          items: <ShuAnnouncementListItem>[
            for (var index = 1; index <= 8; index++)
              stubAnnouncement('a$index'),
          ],
        ),
      );
      await _pumpApp(tester, announcements: client, physical: _shortPhone);
      await _openNotificationsRow(tester);

      expect(find.byKey(NotificationsPage.sourceNoticeKey), findsOneWidget);

      await _scrollToBottom(tester);

      // 它跟着内容一起滑走并**被回收** —— 不是钉在顶上的一行。
      expect(find.byKey(NotificationsPage.sourceNoticeKey), findsNothing);
      expect(find.text('公告 a8'), findsOneWidget, reason: '确实滑到了底');
    });

    testWidgets('an off-site entry is never fetched and opens in the browser', (
      tester,
    ) async {
      final launched = _mockExternalLauncher();
      final item = stubAnnouncement('6432');
      final offsite = ShuAnnouncementListItem(
        title: '校外的一篇',
        url: Uri.parse('https://www.shu.edu.cn/info/1000/1.htm'),
        dateText: '2026-09-20',
        publishedAt: DateTime(2026, 9, 20),
      );
      final client = StubShuAnnouncementClient(
        firstPage: ShuAnnouncementPage(
          items: <ShuAnnouncementListItem>[item, offsite],
        ),
      );
      await _pumpApp(tester, announcements: client);
      await _openNotificationsRow(tester);

      // 照常显示，但**从未被取过**：正文请求里只有本站那一条，它也就没有预览。
      expect(find.text('校外的一篇'), findsOneWidget);
      expect(client.requestedDetails, <Uri>[item.url]);
      expect(find.text('正文第一段。'), findsOneWidget, reason: '本站那条有预览');
      // 行末换成「到外面去」，让人先知道点下去会离开应用。
      expect(find.byIcon(Icons.open_in_new), findsOneWidget);

      await tester.tap(find.text('校外的一篇'));
      await tester.pumpAndSettle();

      expect(find.byType(AnnouncementDetailPage), findsNothing);
      expect(launched, <String>[offsite.url.toString()]);
      expect(client.requestedDetails, <Uri>[item.url], reason: '点开也不取它');
    });

    testWidgets('the list is split by month, one heading per month', (
      tester,
    ) async {
      final client = StubShuAnnouncementClient(
        firstPage: ShuAnnouncementPage(
          items: <ShuAnnouncementListItem>[
            stubAnnouncement('c3', publishedAt: DateTime(2026, 9, 30)),
            stubAnnouncement('c2', publishedAt: DateTime(2026, 9, 2)),
            stubAnnouncement('c1', publishedAt: DateTime(2026, 8, 20)),
            stubAnnouncement('c0', publishedAt: DateTime(2025, 12, 31)),
          ],
        ),
      );
      await _pumpApp(tester, announcements: client);
      await _openNotificationsRow(tester);

      // 同一个月只有一行小字，不管那个月里有几条。
      expect(find.text('2026年 9月'), findsOneWidget);
      expect(find.text('2026年 8月'), findsOneWidget);
      expect(find.text('2025年 12月'), findsOneWidget);
      expect(find.text('2026年 7月'), findsNothing);

      // 小标题在该组第一条之前、上一组最后一条之后。
      final previous = tester.getTopLeft(find.text('公告 c2')).dy;
      final heading = tester.getTopLeft(find.text('2026年 8月')).dy;
      final first = tester.getTopLeft(find.text('公告 c1')).dy;
      expect(previous, lessThan(heading));
      expect(heading, lessThan(first));
    });

    testWidgets('an announcement without a date gets no heading', (
      tester,
    ) async {
      final client = StubShuAnnouncementClient(
        firstPage: ShuAnnouncementPage(
          items: <ShuAnnouncementListItem>[
            ShuAnnouncementListItem(
              title: '没有日期的公告',
              url: Uri.parse('https://newits.shu.edu.cn/info/1095/6000.htm'),
            ),
          ],
        ),
      );
      await _pumpApp(tester, announcements: client);
      await _openNotificationsRow(tester);

      expect(find.text('没有日期的公告'), findsOneWidget);
      expect(find.textContaining(RegExp(r'\d{4}年 \d{1,2}月')), findsNothing);
    });

    testWidgets('opens an item with its body already on screen', (
      tester,
    ) async {
      final item = stubAnnouncement('6432', title: '关于资产清查盘点的通知');
      final client = StubShuAnnouncementClient(
        firstPage: ShuAnnouncementPage(items: <ShuAnnouncementListItem>[item]),
      );
      await _pumpApp(tester, announcements: client);
      await _openNotificationsRow(tester);

      expect(client.requestedDetails, <Uri>[item.url], reason: '列表阶段预取过一次');

      await tester.tap(find.text('关于资产清查盘点的通知'));
      // 推路由一帧、go_router 把新的一页建出来再来一帧；两帧都还在转场里，
      // 没有任何一次网络往返。
      await tester.pump();
      await tester.pump();

      expect(find.byType(AnnouncementDetailPage), findsOneWidget);
      expect(find.text('2026-09-22 · 吕露'), findsOneWidget, reason: '正文第一帧就在');
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(client.requestedDetails, <Uri>[item.url], reason: '没有第二次请求');

      await tester.pumpAndSettle();
    });

    testWidgets('a short list loads the next page when scrolled to the end', (
      tester,
    ) async {
      const second = 'https://newits.shu.edu.cn/index/tzgg/31.htm';
      final client = _pagedClient(
        count: 8,
        next: second,
        pages: <String, ShuAnnouncementPage>{
          second: ShuAnnouncementPage(
            items: <ShuAnnouncementListItem>[stubAnnouncement('a9')],
          ),
        },
      );
      await _pumpApp(tester, announcements: client, physical: _shortPhone);
      await _openNotificationsRow(tester);

      expect(find.text('公告 a9'), findsNothing, reason: '第二页还没被拉过');
      expect(client.requestedPages, <Uri?>[null]);
      expect(find.byKey(NotificationsPage.listEndKey), findsNothing);

      await _scrollToBottom(tester);

      expect(find.text('公告 a9'), findsOneWidget);
      // 续页取的是站点自己在分页里给的地址，不是客户端算出来的页码。
      expect(client.requestedPages, <Uri?>[null, Uri.parse(second)]);
      expect(
        find.byKey(NotificationsPage.listEndKey),
        findsOneWidget,
        reason: '站点说没有下一页了',
      );
    });

    testWidgets('an item repeated across pages is shown once', (tester) async {
      const second = 'https://newits.shu.edu.cn/index/tzgg/31.htm';
      final client = _pagedClient(
        count: 8,
        next: second,
        pages: <String, ShuAnnouncementPage>{
          // 站点按时间倒序排，新发一条会让第二页的第一项和第一页的最后一项
          // 撞上 —— 那一项不该出现两次。
          second: ShuAnnouncementPage(
            items: <ShuAnnouncementListItem>[
              stubAnnouncement('a8'),
              stubAnnouncement('a9'),
            ],
          ),
        },
      );
      await _pumpApp(tester, announcements: client, physical: _shortPhone);
      await _openNotificationsRow(tester);
      await _scrollToBottom(tester);

      expect(find.text('公告 a8'), findsOneWidget);
      expect(find.text('公告 a9'), findsOneWidget);
    });

    testWidgets('an empty list is an empty state, not a blank page', (
      tester,
    ) async {
      await _pumpApp(tester, announcements: StubShuAnnouncementClient());
      await _openNotificationsRow(tester);

      expect(find.text('暂无公告'), findsOneWidget);
      // 没有列表就没有列表的第一行 —— 那行来源说明是跟着列表一起来的。
      expect(find.byKey(NotificationsPage.sourceNoticeKey), findsNothing);
    });

    testWidgets('a failed first page offers a retry that then works', (
      tester,
    ) async {
      final client = StubShuAnnouncementClient(
        listError: Exception('connection refused'),
      );
      await _pumpApp(tester, announcements: client);
      await _openNotificationsRow(tester);

      expect(find.text('通知公告加载失败'), findsOneWidget);
      expect(find.textContaining('connection refused'), findsOneWidget);

      // 站点恢复了：同一个替身换成不再抛错、并且有一页数据。
      client
        ..listError = null
        ..firstPage = ShuAnnouncementPage(
          items: <ShuAnnouncementListItem>[stubAnnouncement('a1')],
        );
      await tester.tap(find.widgetWithText(FilledButton, '重试'));
      await tester.pumpAndSettle();

      expect(find.text('通知公告加载失败'), findsNothing);
      expect(find.text('公告 a1'), findsOneWidget);
    });
  });

  group('通知详情', () {
    testWidgets('renders the parsed blocks and the metadata', (tester) async {
      final item = stubAnnouncement('6432', title: '关于资产清查盘点的通知');
      final attachment = Uri.parse(
        'https://newits.shu.edu.cn/system/_content/download.jsp?wbfileid=CB68',
      );
      final client = StubShuAnnouncementClient(
        firstPage: ShuAnnouncementPage(items: <ShuAnnouncementListItem>[item]),
        details: <String, ShuAnnouncementDetail>{
          item.url.toString(): stubAnnouncementDetail(
            item,
            blocks: <ShuAnnouncementBlock>[
              const ShuAnnouncementText('各学院（部门）：'),
              ShuAnnouncementAttachment('自查表.rar', attachment),
            ],
          ),
        },
      );
      await _pumpApp(tester, announcements: client);
      await _openNotificationsRow(tester);

      await tester.tap(find.text('关于资产清查盘点的通知'));
      await tester.pumpAndSettle();

      expect(find.byType(AnnouncementDetailPage), findsOneWidget);
      expect(find.text('通知详情'), findsOneWidget, reason: '顶栏标题');
      // 跳转按钮与列表里外站条目那个是同一个图标。
      expect(find.byIcon(Icons.open_in_new), findsOneWidget);
      expect(find.text('各学院（部门）：'), findsOneWidget);
      expect(find.text('2026-09-22 · 吕露'), findsOneWidget);
      expect(find.text('自查表.rar'), findsOneWidget);
      expect(client.requestedDetails, <Uri>[item.url]);
    });

    testWidgets('a link inside the body opens through the system browser', (
      tester,
    ) async {
      final item = stubAnnouncement('6432');
      final link = Uri.parse('https://newsso.shu.edu.cn/oauth2/mailRegister');
      final launched = _mockExternalLauncher();

      final client = StubShuAnnouncementClient(
        firstPage: ShuAnnouncementPage(items: <ShuAnnouncementListItem>[item]),
        details: <String, ShuAnnouncementDetail>{
          item.url.toString(): stubAnnouncementDetail(
            item,
            blocks: <ShuAnnouncementBlock>[
              ShuAnnouncementText.rich(<ShuAnnouncementInline>[
                const ShuAnnouncementInline('如需申请邮箱，请点击这里：'),
                ShuAnnouncementInline('上海大学邮箱申请', url: link),
              ]),
            ],
          ),
        },
      );
      await _pumpApp(tester, announcements: client);
      await _openNotificationsRow(tester);
      await tester.tap(find.text('公告 6432'));
      await tester.pumpAndSettle();

      // 正文那一段是富文本，列表里那一行预览是纯文字 —— 用「有 textSpan」
      // 把两者分开。
      final paragraph = find.byWidgetPredicate(
        (widget) =>
            widget is Text &&
            widget.textSpan != null &&
            widget.textSpan!.toPlainText() == '如需申请邮箱，请点击这里：上海大学邮箱申请',
      );
      expect(paragraph, findsOneWidget);

      final spans = (tester.widget<Text>(paragraph).textSpan! as TextSpan)
          .children!
          .whereType<TextSpan>()
          .toList();
      final linked = spans.firstWhere((span) => span.text == '上海大学邮箱申请');
      expect(linked.recognizer, isNotNull);
      expect(linked.style?.decoration, TextDecoration.underline);

      // 直接触发那个回调（等价于点上去）。
      (linked.recognizer! as TapGestureRecognizer).onTap!();
      await tester.pumpAndSettle();
      expect(launched, <String>[link.toString()], reason: '交给系统浏览器打开');
    });

    testWidgets('a table in the body is laid out as a grid', (tester) async {
      final item = stubAnnouncement('6432');
      final client = StubShuAnnouncementClient(
        firstPage: ShuAnnouncementPage(items: <ShuAnnouncementListItem>[item]),
        details: <String, ShuAnnouncementDetail>{
          item.url.toString(): stubAnnouncementDetail(
            item,
            blocks: <ShuAnnouncementBlock>[
              const ShuAnnouncementTable(
                hasHeaderRow: true,
                rows: <List<ShuAnnouncementTableCell>>[
                  <ShuAnnouncementTableCell>[
                    ShuAnnouncementTableCell(<ShuAnnouncementInline>[
                      ShuAnnouncementInline('模块'),
                    ]),
                    ShuAnnouncementTableCell(<ShuAnnouncementInline>[
                      ShuAnnouncementInline('主要内容'),
                    ]),
                  ],
                  <ShuAnnouncementTableCell>[
                    ShuAnnouncementTableCell(<ShuAnnouncementInline>[
                      ShuAnnouncementInline('信创入门'),
                    ]),
                    ShuAnnouncementTableCell(<ShuAnnouncementInline>[
                      ShuAnnouncementInline('什么是信创？'),
                    ]),
                  ],
                ],
              ),
            ],
          ),
        },
      );
      await _pumpApp(tester, announcements: client);
      await _openNotificationsRow(tester);
      await tester.tap(find.text('公告 6432'));
      await tester.pumpAndSettle();

      expect(find.byType(Table), findsOneWidget);
      final table = tester.widget<Table>(find.byType(Table));
      expect(table.children, hasLength(2));
      // 每行的格子数必须一致 —— 不一致的话 `Table` 会直接抛断言。
      expect(
        table.children.every((row) => row.children.length == 2),
        isTrue,
        reason: '两列',
      );
      expect(find.text('模块'), findsOneWidget);
      expect(find.text('什么是信创？'), findsOneWidget);
    });

    testWidgets(
      'a failed body offers a retry, and then shows the fallback title',
      (tester) async {
        final item = stubAnnouncement('6432');
        final client = StubShuAnnouncementClient(
          firstPage: ShuAnnouncementPage(
            items: <ShuAnnouncementListItem>[item],
          ),
          detailError: Exception('超时'),
        );
        await _pumpApp(tester, announcements: client);
        await _openNotificationsRow(tester);

        await tester.tap(find.text('公告 6432'));
        await tester.pumpAndSettle();

        expect(find.text('公告加载失败'), findsOneWidget);
        expect(find.textContaining('超时'), findsOneWidget);

        // 站点恢复了。正文里取不到标题时用**列表带进来的**那一个兜底 ——
        // 那正是 `item` 一路传进这一页的原因。
        client.detailError = null;
        await tester.tap(find.widgetWithText(FilledButton, '重试'));
        await tester.pumpAndSettle();

        expect(find.text('公告加载失败'), findsNothing);
        expect(find.text('公告 6432'), findsOneWidget);
        expect(find.text('正文第一段。'), findsOneWidget);
      },
    );
  });
}
