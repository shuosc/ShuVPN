/// Static identity of the app.
///
/// Kept as constants (instead of `package_info_plus`) so the about page, the
/// settings subtitle and the Android build metadata can never drift apart in
/// a way the user would notice. Bump these together with `pubspec.yaml`.
abstract final class ShuAppInfo {
  static const String name = 'ShuVPN';
  static const String version = '0.3.0';
  static const String buildLabel = '4';

  /// 显示用的版本号。括号用**全角**：它只出现在中文语境里（关于页、许可页）。
  static const String versionLabel = '$version（$buildLabel）';

  static const String tagline = '上大 aTrust RVPN 客户端';
  static const String disclaimer = '本应用与上海大学无隶属关系。';

  static const String repository = 'https://github.com/shuosc/ShuVPN';

  /// 仓库里那份 `LICENSE` 的标题。照它的第一行写，不简写成 `AGPL-3.0`：
  /// 关于页上的这一行是给「想确认许可条款」的人看的，缩写对不上文件。
  static const String licenseName = 'GNU Affero General Public License v3.0';

  static const String contributorsUrl =
      'https://github.com/shuosc/ShuVPN/graphs/contributors';
}
