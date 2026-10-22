import 'dart:convert';
import 'dart:io';

import 'shu_update_info.dart';
import 'shu_release_target.dart';

/// 远端最新版本的一次查询。
///
/// 抽成接口只为让测试塞替身：启动路径每次都会跑它，而 widget 测试不该真的
/// 发请求。
abstract interface class ShuUpdateClient {
  /// 远端比 [currentVersion] 新时返回结论；已经是最新、或上游还没有正式发布
  /// 时返回 null。失败抛 [ShuUpdateException]。
  Future<ShuUpdateInfo?> checkForUpdate(String currentVersion);
}

/// 走 GitHub Releases 的实现。
///
/// 只问 `releases/latest` 一个端点，所以不需要令牌：GitHub 对匿名请求的限额
/// 是每 IP 每小时 60 次，而这份代码每次启动最多问一次。
class GithubReleaseClient implements ShuUpdateClient {
  GithubReleaseClient({Uri? latestReleaseUri, ShuReleaseTarget? target})
    : latestReleaseUri = latestReleaseUri ?? defaultLatestReleaseUri,
      target = target ?? ShuReleaseTarget.current;

  static final Uri defaultLatestReleaseUri = Uri.parse(
    'https://api.github.com/repos/shuosc/ShuVPN/releases/latest',
  );

  final Uri latestReleaseUri;
  final ShuReleaseTarget? target;

  /// 单次请求的超时。
  ///
  /// 启动路径上它顶在用户面前：一次卡住的请求不该让弹窗在十几秒后才冒出来，
  /// 那时用户已经在干别的事了。
  static const Duration timeout = Duration(seconds: 8);

  @override
  Future<ShuUpdateInfo?> checkForUpdate(String currentVersion) async {
    final json = await _fetchLatestRelease();
    if (json == null) return null;
    return updateInfoFromReleaseJson(
      json,
      currentVersion: currentVersion,
      target: target,
    );
  }

  /// 读一次 `releases/latest`；404（上游一个正式发布都没有）返回 null。
  Future<Map<String, Object?>?> _fetchLatestRelease() async {
    // 每次调用新建一个客户端：`HttpClient` 用完必须关，而这份对象是应用级的，
    // 没有哪一处的生命期比这次请求更适合持有它。
    final client = HttpClient();
    try {
      final request = await client.getUrl(latestReleaseUri).timeout(timeout);
      request.headers
        ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
        // 缺 User-Agent 会被 GitHub 直接拒掉。
        ..set(HttpHeaders.userAgentHeader, 'ShuVPN')
        // 不带版本时 GitHub 按最旧的语义返回。
        ..set('X-GitHub-Api-Version', '2022-11-28');

      final response = await request.close().timeout(timeout);
      if (response.statusCode == HttpStatus.notFound) {
        await response.drain<void>();
        return null;
      }
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        throw ShuUpdateException(
          'GitHub 返回 HTTP ${response.statusCode}，可能是访问限额用尽或服务不可用',
        );
      }
      final decoded = jsonDecode(body);
      if (decoded is! Map) {
        throw const ShuUpdateException('GitHub 返回的不是一个发布对象');
      }
      return decoded.cast<String, Object?>();
    } on ShuUpdateException {
      rethrow;
    } on Object catch (error) {
      throw ShuUpdateException('$error');
    } finally {
      client.close(force: true);
    }
  }
}

/// 从 `releases/latest` 的响应体里读出更新结论，没有更新时返回 null。
///
/// 独立成纯函数是因为判断都集中在这里（挑哪个资产、算不算更新），而网络那一
/// 半没有可测的分支。
ShuUpdateInfo? updateInfoFromReleaseJson(
  Map<String, Object?> json, {
  required String currentVersion,
  ShuReleaseTarget? target,
}) {
  final latestVersion = stripVersionTag(json['tag_name']);
  if (latestVersion.isEmpty) return null;
  if (compareShuVersions(latestVersion, currentVersion) <= 0) return null;
  return ShuUpdateInfo(
    latestVersion: latestVersion,
    downloadUrl: pickReleaseDownloadUrl(
      json['assets'],
      version: latestVersion,
      tag: _stringValue(json['tag_name']).trim(),
      target: target,
    ),
    releasePageUrl: _stringValue(json['html_url']),
    publishedAt: DateTime.tryParse(_stringValue(json['published_at'])),
  );
}

/// 标签名去掉 `v` / `V` 前缀。
String stripVersionTag(Object? tag) {
  var text = _stringValue(tag).trim();
  if (text.startsWith('v') || text.startsWith('V')) {
    text = text.substring(1);
  }
  return text;
}

/// Select only a published asset for this exact version, platform and ABI.
/// Never guess a URL or fall back to another ABI, a universal APK or a legacy
/// unlabelled APK. Missing assets leave the release page available to callers.
String pickReleaseDownloadUrl(
  Object? assets, {
  required String version,
  required String tag,
  required ShuReleaseTarget? target,
}) {
  if (target == null || assets is! List) return '';
  final name = target.assetName(version);
  final expectedUri = Uri.https(
    'github.com',
    '/shuosc/ShuVPN/releases/download/$tag/$name',
  );
  for (final asset in assets) {
    if (asset is! Map || asset['name'] != name) continue;
    if (asset['state'] != null && asset['state'] != 'uploaded') continue;
    final uri = Uri.tryParse(
      _stringValue(asset['browser_download_url']).trim(),
    );
    if (uri == expectedUri) return uri.toString();
  }
  return '';
}

String _stringValue(Object? value) => value is String ? value : '';
