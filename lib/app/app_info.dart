import 'package:flutter/services.dart';

/// 应用的身份信息。
///
/// [version] 与 [buildLabel] **不是写在这里的**：`appBuildName` /
/// `appBuildNumber` 是编译期常量，值由 Flutter 工具从 `pubspec.yaml` 的
/// `version:` 取（`0.4.1+8` → `0.4.1` 与 `8`），或取构建时的 `--build-name`
/// / `--build-number`；两者都在声明处被折进常量，没有一次运行期查询。
/// 所以**升版本只改 `pubspec.yaml` 一处**。
///
/// 它与 APK 的 `versionName` / `versionCode` 同源 —— `android/app/`
/// 里那两行读的就是 `flutter.versionName` / `flutter.versionCode`，同一个
/// `version:` 推出来的。应用里显示的版本号因此不可能与实际装着的那个包
/// 不一致。
///
/// 兜底值只在**编译时拿不到这两项**时生效（`pubspec.yaml` 没有 `version:`，
/// 而且构建时也没给 `--build-name`）—— 那意味着不是经 Flutter 工具编的。
/// 它们的作用是让这两个字段保持非空，调用方都在拼字符串。
abstract final class ShuAppInfo {
  static const String name = 'ShuVPN';

  /// 版本名，如 `0.4.1`。
  static const String version = appBuildName ?? '0.0.0';

  /// 构建号，如 `8`。
  static const String buildLabel = appBuildNumber ?? '0';

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
