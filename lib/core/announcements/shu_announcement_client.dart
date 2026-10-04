import 'dart:io';
import 'dart:typed_data';

import 'shu_announcement.dart';
import 'shu_announcement_parser_host.dart';

/// 公告站点的主机名。这个应用只请求它。
const String shuAnnouncementHost = 'newits.shu.edu.cn';

/// [url] 是不是本应用该去取的公告地址。
///
/// 列表页里混着指向外站的条目 —— 站点把「换个地方看」的链接也当成一条排进
/// 列表，解析出来的地址就在别的域上。那些条目照常显示（标题、日期都是真的），
/// 但不该把它们当公告去拉：这不是公告站的内容，拉回来也排不出正文，而且一次
/// 预取十篇就等于替站点去访问十个它指到的地方。
///
/// 判据是主机名**精确**相等，不做子域通配：这个站没有子域，「以它结尾」反而
/// 会把 `newits.shu.edu.cn.example.com` 放进来。CNAME 到 `web10.shu.edu.cn`
/// 是 DNS 层的事，请求里的 Host 仍然是这里写的那个。
bool isShuAnnouncementUrl(Uri url) => url.host == shuAnnouncementHost;

/// 信息办公告的一个通道。
///
/// 抽成接口只为让测试塞替身：通知页一打开就会拉列表，而 widget 测试既不该
/// 真的发请求，也不该依赖 shu.edu.cn 的返回。
///
/// 接口里有 [cachedDetail] 这样一个**同步**读法，是这一层与别处不同的地方：
/// 通知页会把列表里每一篇的正文先取回来（为了那两行预览），于是点开时正文
/// 已经在手上了。详情页因此能不经过 `FutureBuilder` 直接把它画出来 —— 没有
/// 第一帧的转圈，也没有「先白一下再出内容」。
abstract interface class ShuAnnouncementClient {
  /// 拉一页列表；[page] 为 null 时拉第一页。
  Future<ShuAnnouncementPage> fetchList({Uri? page});

  Future<ShuAnnouncementDetail> fetchDetail(ShuAnnouncementListItem item);

  /// 已经取回来过的那一篇；没有则为 null，调用方自己去 [fetchDetail]。
  ShuAnnouncementDetail? cachedDetail(Uri url);

  /// 收掉这条通道背后的资源。
  ///
  /// 真实现背后是一条常驻的解析 isolate，它活到进程结束，所以会调它的只有
  /// provider 的 `dispose` 与测试；替身没有要收的东西。
  void close();
}

/// 走 `newits.shu.edu.cn` 上那份 HTML 的实现。
///
/// 站点没有 API，只有服务端渲染好的模板，所以这里做的是「取 HTML + 解析」。
/// 这个类只剩取与那份正文缓存 —— 解码与解析都在 [ShuAnnouncementParserHost]
/// 的 isolate 上做。
class NewitsAnnouncementClient implements ShuAnnouncementClient {
  NewitsAnnouncementClient();

  /// 后台解析通道。见 [ShuAnnouncementParserHost] 里「界面 isolate 上一帧也
  /// 不能搭进去」那段说明。
  final ShuAnnouncementParserHost _parser = ShuAnnouncementParserHost();

  /// 正文缓存，以条目地址的字符串为键。
  ///
  /// 站点的列表项没有摘要，列表里那两行预览是**从正文里摘的**，所以列表每往
  /// 前走一屏，就会有十篇正文落到这里。
  final Map<String, ShuAnnouncementDetail> _cache =
      <String, ShuAnnouncementDetail>{};

  /// 缓存条数上限。
  ///
  /// 一路滑到底会经过三百多篇公告，不封顶就等于把整站正文留在内存里。超了
  /// 就丢**最早**那几篇 —— 它们已经滚出列表很远，真要再看时重拉一次即可。
  static const int cacheLimit = 64;

  /// 通知公告栏目的入口。
  ///
  /// 它永远是最新那一页：站点那一栏的页码是倒着编的（第一页就是这个地址，
  /// 第 k 页是 `index/tzgg/{总页数+1-k}.htm`），首页地址不会随公告数变化，
  /// 而任何写死的页码都会。
  static final Uri listUrl = Uri.parse(
    'https://newits.shu.edu.cn/index/tzgg.htm',
  );

  /// 单次请求的超时。列表要能在一屏之内出结果，慢过这个数就不值得再等。
  static const Duration timeout = Duration(seconds: 10);

  @override
  Future<ShuAnnouncementPage> fetchList({Uri? page}) async {
    final target = page ?? listUrl;
    // 分页链接是站点自己给的。就算它哪天指到别处，也不跟过去。
    if (!isShuAnnouncementUrl(target)) {
      throw ShuAnnouncementException('不取 ${target.host} 上的页面');
    }
    return _parser.parseList(await _get(target), baseUri: target);
  }

  @override
  Future<ShuAnnouncementDetail> fetchDetail(
    ShuAnnouncementListItem item,
  ) async {
    // 调用方本该先问过 [isShuAnnouncementUrl]；这里再拦一道，把「只取本站」
    // 变成这一层的承诺，而不是每个调用点各自记得的约定。
    if (!isShuAnnouncementUrl(item.url)) {
      throw ShuAnnouncementException('不取 ${item.url.host} 上的内容');
    }
    final cached = cachedDetail(item.url);
    if (cached != null) return cached;
    final detail = await _parser.parseDetail(
      await _get(item.url),
      url: item.url,
      fallbackTitle: item.title,
      fallbackDateText: item.dateText,
    );
    _remember(item.url, detail);
    return detail;
  }

  @override
  ShuAnnouncementDetail? cachedDetail(Uri url) => _cache[url.toString()];

  @override
  void close() => _parser.close();

  void _remember(Uri url, ShuAnnouncementDetail detail) {
    _cache[url.toString()] = detail;
    while (_cache.length > cacheLimit) {
      _cache.remove(_cache.keys.first);
    }
  }

  /// 取一页 HTML 的**原始字节**。
  ///
  /// 解码交给后台解析 isolate：几百 KB 的 UTF-8 解出来是一整个字符串，那一笔
  /// 时间属于解析，不属于界面。
  ///
  /// 每次调用新建一个 `HttpClient`：它用完必须关，而这份对象没有哪一处的
  /// 生命期比这次请求更适合持有它（与 `GithubReleaseClient` 同）。
  Future<Uint8List> _get(Uri uri) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(uri).timeout(timeout);
      request.headers
        ..set(HttpHeaders.acceptHeader, 'text/html,application/xhtml+xml')
        // 站点不带 UA 也能返回 200，带上是为了万一被按客户端分派模板时
        // 拿到的是与浏览器一致的那一份。
        ..set(
          HttpHeaders.userAgentHeader,
          'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
        );

      final response = await request.close().timeout(timeout);
      // 响应体一律要读完，否则连接不会还给连接池。失败时读掉再抛。
      final body = await response
          .fold<BytesBuilder>(
            BytesBuilder(copy: false),
            (builder, chunk) => builder..add(chunk),
          )
          .timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw ShuAnnouncementException(
          '信息办公告返回 HTTP ${response.statusCode}',
          statusCode: response.statusCode,
        );
      }
      return body.takeBytes();
    } on ShuAnnouncementException {
      rethrow;
    } on Object catch (error) {
      throw ShuAnnouncementException('$error');
    } finally {
      client.close(force: true);
    }
  }
}
