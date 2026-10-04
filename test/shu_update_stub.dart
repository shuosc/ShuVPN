import 'package:shuvpn/core/update/shu_update_client.dart';
import 'package:shuvpn/core/update/shu_update_info.dart';

/// 一个不发请求的更新通道。
///
/// 启动路径每次都会查一次更新，而 widget 测试既不该碰网络，也不该依赖 GitHub
/// 的返回 —— 凡是 pump 整个应用的地方都装上它。
class StubShuUpdateClient implements ShuUpdateClient {
  StubShuUpdateClient({this.result, this.error});

  /// 要返回的结果。null 表示「已经是最新」。
  final ShuUpdateInfo? result;

  /// 要抛出的异常。给了它就不再返回 [result]，用来走失败分支。
  final Object? error;

  /// 收到过的本地版本号，供断言「比较的是应用自己的版本」。
  final List<String> requestedVersions = <String>[];

  @override
  Future<ShuUpdateInfo?> checkForUpdate(String currentVersion) async {
    requestedVersions.add(currentVersion);
    final failure = error;
    if (failure != null) throw failure;
    return result;
  }
}
