import 'package:shuvpn/core/announcements/shu_announcement.dart';
import 'package:shuvpn/core/announcements/shu_announcement_client.dart';

/// 一条测试用公告。地址按站点真实的形状拼，去重也是按地址做的。
///
/// 日期默认 2026-09-22；要验「按月份分组」时传 [publishedAt]，[dateText] 跟着
/// 它一起算（除非显式给）。
ShuAnnouncementListItem stubAnnouncement(
  String id, {
  String? title,
  DateTime? publishedAt,
  String? dateText,
}) {
  final at = publishedAt ?? DateTime(2026, 9, 22);
  return ShuAnnouncementListItem(
    title: title ?? '公告 $id',
    url: Uri.parse('https://newits.shu.edu.cn/info/1095/$id.htm'),
    dateText: dateText ?? _isoDate(at),
    publishedAt: at,
  );
}

/// 站点列表上那种 `2026-09-22`。
String _isoDate(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

/// 一篇测试用公告正文。
ShuAnnouncementDetail stubAnnouncementDetail(
  ShuAnnouncementListItem item, {
  List<ShuAnnouncementBlock>? blocks,
}) {
  return ShuAnnouncementDetail(
    title: item.title,
    url: item.url,
    dateText: item.dateText,
    publishedAt: item.publishedAt,
    author: '吕露',
    blocks:
        blocks ?? const <ShuAnnouncementBlock>[ShuAnnouncementText('正文第一段。')],
  );
}

/// 一个不发请求的公告通道。
///
/// 通知页一打开就拉列表，而 widget 测试既不该碰网络，也不该依赖 shu.edu.cn
/// 的返回 —— 凡是 pump 到通知页的地方都装上它。
///
/// 四个数据字段都是**可变**的，因为「失败之后重试」这类用例要在两次调用之间
/// 把替身换个状态。
class StubShuAnnouncementClient implements ShuAnnouncementClient {
  StubShuAnnouncementClient({
    this.firstPage = const ShuAnnouncementPage(items: []),
    this.pages = const <String, ShuAnnouncementPage>{},
    this.details = const <String, ShuAnnouncementDetail>{},
    this.listError,
    this.detailError,
  });

  /// 第一页（`fetchList()` 不带地址时）。
  ShuAnnouncementPage firstPage;

  /// 续页，以请求地址的字符串为键。
  Map<String, ShuAnnouncementPage> pages;

  /// 正文，以条目地址的字符串为键。没配的条目回一个默认正文。
  Map<String, ShuAnnouncementDetail> details;

  /// 非 null 时列表调用直接抛它，用来走失败分支。
  Object? listError;

  /// 同上，正文那一条路。
  Object? detailError;

  /// 收到过的列表地址，null 表示「第一页」。
  final List<Uri?> requestedPages = <Uri?>[];

  /// 收到过的正文地址。
  final List<Uri> requestedDetails = <Uri>[];

  /// 取回来过的正文。真实现也这么存 —— 详情页会先问它，命中就不过
  /// `FutureBuilder`（那是「点开即读」的实现）。
  final Map<String, ShuAnnouncementDetail> _cache =
      <String, ShuAnnouncementDetail>{};

  @override
  Future<ShuAnnouncementPage> fetchList({Uri? page}) async {
    requestedPages.add(page);
    final failure = listError;
    if (failure != null) throw failure;
    if (page == null) return firstPage;
    return pages[page.toString()] ?? const ShuAnnouncementPage(items: []);
  }

  @override
  Future<ShuAnnouncementDetail> fetchDetail(
    ShuAnnouncementListItem item,
  ) async {
    requestedDetails.add(item.url);
    final failure = detailError;
    if (failure != null) throw failure;
    final detail = details[item.url.toString()] ?? stubAnnouncementDetail(item);
    _cache[item.url.toString()] = detail;
    return detail;
  }

  @override
  ShuAnnouncementDetail? cachedDetail(Uri url) => _cache[url.toString()];

  @override
  void close() {}
}
