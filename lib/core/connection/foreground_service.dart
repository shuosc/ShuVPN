import 'dart:io';

import '../logging/shu_log.dart';
import 'shu_android_vpn.dart';

/// 前台服务这一格 —— 把「进程留在前台」当资源管。
///
/// ## 为什么两种数据面共用它
///
/// 系统 VPN（`VpnService`）与两个本机代理（SOCKS5 / HTTP）**共用一个服务、
/// 一条通知**。理由不是省事：只有 `VpnService` 能调 `Builder.establish()`，
/// 而一个平级的普通 `Service` 只会多出一条通知、多一套生命周期，还要在
/// 「用户把 VPN 关掉但代理留着」的那一下做一次交接。服务类是 VPN 的子类，
/// 纯代理模式下它只是不建接口而已。
///
/// 代理那一侧更需要它：那两个服务器是 `dart:io` 的 `ServerSocket`，进程一被
/// 后台回收，端口就没了，而界面还写着「已连接」。前台服务是这种「没有任何
/// 系统级痕迹的常驻服务」唯一的保护。
///
/// ## 它的规则
///
/// * [attach] 幂等 —— 三个数据面各自起来时都可能叫它，重复叫不会多出什么。
/// * [releaseIfIdle] 只在**调用方确认没人需要**时才撤。判断「有没有人需要」
///   留在调用方（`ConnectionController`）：这里有三个数据面，谁能代表
///   「还需要」，只有它数得清。
/// * [markAttached] 是给原生侧那条路留的口子 —— `ShuAndroidVpn.start` 自己
///   就会起服务（它必须这么做：只有服务能建 TUN），那一侧不会走 [attach]。
///
/// 名字里的 `Shu` 前缀与同层的 `ShuVpnNotification` 一致：两个都是那条常驻
/// 通知的一半（一个管服务，一个管内容）。
class ShuForegroundService {
  /// 服务是不是在跑。原生侧把它拉起来过（[markAttached]）也算。
  bool get attached => _attached;

  bool _attached = false;

  /// 这台设备有没有「前台服务」这回事 —— 只有 Android 有。
  ///
  /// 与 `ShuVpnPermission.isSupported` 同一条思路：抽出来是为测试，别处
  /// 不该自己看 `Platform`。
  bool get isSupported => Platform.isAndroid;

  /// 把服务拉起来（幂等），返回**这一下是否真的把它拉起来了**。
  ///
  /// 返回值只给一个用途：刚起来的这一下要立刻推第一帧通知内容 —— 否则那条
  /// 通知会先停在原生侧那句「已连接」上，等一秒后第一次采样才换成读数行。
  /// 已经在跑时返回 false，因为采样循环本来就在推。
  ///
  /// 失败只记一行 DEBUG：它没拦着任何数据面，而调用它的是「刚把代理开关
  /// 拨开」这类动作 —— 把异常抛出去只会让人以为代理没起来。
  Future<bool> attach() async {
    if (_attached || !isSupported) return false;
    try {
      await ShuAndroidVpn.attachForeground();
    } on Object catch (error) {
      ShuLog.d(ShuLogTag.vpn, '启动前台服务失败：$error');
      return false;
    }
    _attached = true;
    ShuLog.i(ShuLogTag.vpn, '已进入前台：常驻通知已挂上，进程不再被后台回收');
    return true;
  }

  /// 服务是被**原生侧**拉起来的（`ShuAndroidVpn.start` 的第一步就是起服务）。
  ///
  /// 那一侧的代码在 Kotlin 里，不会绕回这里调 [attach]，所以由调用方记一笔
  /// —— 不记的话，后面「没人需要了就撤掉」那条判断会以为服务根本没起来，
  /// 于是它永远撤不掉。
  ///
  /// 记在 `start` **之前**：那个调用可能失败（服务起来了、接口没建成），
  /// 而失败时同样要能把服务收掉。记早了没有代价 —— 服务确实没起来时，
  /// 收尾那次 `stop` 是一次空操作。
  void markAttached() => _attached = true;

  /// 已经没有数据面需要它了就把服务撤掉。
  ///
  /// [stillNeeded] 由调用方算：**三个数据面里还有任意一个在跑**就是 true。
  /// 多撤一次的后果是把还在用的代理连同进程保护一起撤掉，少撤一次的后果是
  /// 通知栏上留着一条「已连接」而实际什么都没在转 —— 两种都算错，所以这条
  /// 判断只有调用方做得了（它手里有三个数据面的字段）。
  Future<void> releaseIfIdle({required bool stillNeeded}) async {
    if (!_attached || stillNeeded) return;
    _attached = false;
    try {
      await ShuAndroidVpn.detachForeground();
    } on Object catch (error) {
      ShuLog.d(ShuLogTag.vpn, '停掉前台服务失败：$error');
    }
    ShuLog.i(ShuLogTag.vpn, '已离开前台：常驻通知已撤下');
  }
}
