/// 一条「远端有新版本」的结论。
///
/// 只保留弹窗与跳转用得上的字段。上游 release 的正文与 `*.sha256` 校验文件
/// 不进来 —— 正文是 CI 自动生成的模板，对用户是噪音。
class ShuUpdateInfo {
  const ShuUpdateInfo({
    required this.latestVersion,
    required this.downloadUrl,
    required this.releasePageUrl,
    this.publishedAt,
  });

  /// 远端标签去掉 `v` 前缀后的版本名，与 `pubspec.yaml` 的 `version` 同名。
  final String latestVersion;

  /// APK 资产的直链。发布里没有任何 apk 资产时为空。
  final String downloadUrl;

  /// 发布页地址。它是「没有 apk 可下」时的兜底，也是最坏情况下唯一能给的去处。
  final String releasePageUrl;

  final DateTime? publishedAt;

  bool get hasDownloadUrl => downloadUrl.trim().isNotEmpty;

  /// 点「更新」时该打开的地址。
  String get targetUrl => hasDownloadUrl ? downloadUrl.trim() : releasePageUrl;
}

/// 更新检查失败。
///
/// [toString] 直接返回 [message]：它唯一的去处是 snack 里那句
/// 「检查更新失败：…」，带上异常类名只会让用户多看到一行英文。
class ShuUpdateException implements Exception {
  const ShuUpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 比较两个版本名：[a] 比 [b] 新返回正数，相同返回 0，旧返回负数。
///
/// 只实现这套发布流程用得到的部分：
///
/// * `v` 前缀忽略 —— 标签是 `v0.3.0`，`pubspec.yaml` 里是 `0.3.0`；
/// * 段数不同按缺 0 处理，`0.3` 与 `0.3.0` 相等；
/// * 预发布后缀按 semver 排在同版本正式版之前（`0.4.0-beta.1` < `0.4.0`）。
///   现在的发布都是正式版，但本地调试版会带后缀，不排这一层它就会被判成
///   新版本而反复提示。
///
/// 构建号（`+4`）不参与比较，也无从比较：GitHub 的标签里没有它。代价是
/// 「同一个版本名、不同构建号」的两次发布区分不出来 —— 上游的发布流程不允许
/// 一个标签指向两个提交，所以这种情况不会出现。
int compareShuVersions(String a, String b) {
  final left = _parseVersion(a);
  final right = _parseVersion(b);

  final coreLength = left.core.length > right.core.length
      ? left.core.length
      : right.core.length;
  for (var i = 0; i < coreLength; i++) {
    final leftPart = i < left.core.length ? left.core[i] : 0;
    final rightPart = i < right.core.length ? right.core[i] : 0;
    if (leftPart != rightPart) return leftPart.compareTo(rightPart);
  }

  if (left.preRelease.isEmpty && right.preRelease.isEmpty) return 0;
  // 有预发布后缀的那个更旧。
  if (left.preRelease.isEmpty) return 1;
  if (right.preRelease.isEmpty) return -1;

  final preLength = left.preRelease.length > right.preRelease.length
      ? left.preRelease.length
      : right.preRelease.length;
  for (var i = 0; i < preLength; i++) {
    // 段数少的一方更旧：`beta` < `beta.1`。
    if (i >= left.preRelease.length) return -1;
    if (i >= right.preRelease.length) return 1;
    final leftPart = left.preRelease[i];
    final rightPart = right.preRelease[i];
    final leftNumber = int.tryParse(leftPart);
    final rightNumber = int.tryParse(rightPart);
    final comparison = switch ((leftNumber, rightNumber)) {
      (final int l, final int r) => l.compareTo(r),
      // 数字段排在字母段之前，与 semver 一致。
      (final int _, null) => -1,
      (null, final int _) => 1,
      _ => leftPart.compareTo(rightPart),
    };
    if (comparison != 0) return comparison;
  }
  return 0;
}

class _ParsedVersion {
  const _ParsedVersion(this.core, this.preRelease);

  final List<int> core;
  final List<String> preRelease;
}

_ParsedVersion _parseVersion(String raw) {
  var text = raw.trim();
  if (text.startsWith('v') || text.startsWith('V')) {
    text = text.substring(1);
  }
  final buildSeparator = text.indexOf('+');
  if (buildSeparator >= 0) text = text.substring(0, buildSeparator);
  final preSeparator = text.indexOf('-');
  final coreText = preSeparator < 0 ? text : text.substring(0, preSeparator);
  final preText = preSeparator < 0 ? '' : text.substring(preSeparator + 1);
  return _ParsedVersion(
    // 认不出的段按 0 处理：一个畸形标签不该让整次检查抛异常。
    coreText
        .split('.')
        .map((part) => int.tryParse(part.trim()) ?? 0)
        .toList(growable: false),
    preText.isEmpty
        ? const <String>[]
        : preText.split('.').map((part) => part.trim()).toList(growable: false),
  );
}
