import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_sangfor/flutter_sangfor.dart';

import '../logging/shu_log.dart';

/// ShuVPN 自己的 Android 系统 VPN（`VpnService`）。
///
/// ## 为什么不用 `flutter_sangfor` 的 `AndroidVpnDevice`
///
/// 那份实现在原生侧把**唯一的一条路由丢掉了**。它的 `VpnTunnelService`
/// 有一段「别让 DNS 查询绕进隧道」的保护：
///
/// ```kotlin
/// val effectiveDns = dnsServers.ifEmpty { underlyingDnsServers() }
/// for (route in routes) {
///     if (effectiveDns.any { routeCovers(prefix, length, it) }) continue
///     builder.addRoute(prefix, length)
/// }
/// ```
///
/// 而 `routeCovers("0.0.0.0", 0, dns)` 里的掩码是 `0`，所以
/// `(0 and 0) == (dns and 0)` **永远成立** —— `0.0.0.0/0` 被判成「覆盖了
/// DNS 服务器」而被跳过。`effectiveDns` 又由底层网络的 DNS 兜底、几乎不会
/// 为空，于是 `Builder` 一条 `addRoute` 都没加上：接口建好了、通知栏出来了、
/// 系统却一个包都不往 TUN 里送。这正是「VPN 开着但没劫持任何流量」。
///
/// 另外那份实现**没有把自己排除在 VPN 之外**（注释说调用方会通过路由排除
/// 隧道节点，但代码里没有）：就算路由修好，隧道自己连网关的 socket 也会被
/// `0.0.0.0/0` 吸进 TUN，绕回自己。
///
/// 两处都在依赖包的原生代码里，app 侧改不动，所以这一层由 `ShuVpnService`
/// + `ShuVpnPlugin` 自己实现（见 `android/app/src/main/kotlin`）。这里只
/// 复用依赖包公开导出的 [FdPacketDevice]：把原生交过来的 fd 变成包流。
class ShuAndroidVpn {
  const ShuAndroidVpn._();

  static const MethodChannel _channel = MethodChannel('shuvpn/vpn');

  static final StreamController<void> _disconnectRequests =
      StreamController<void>.broadcast();
  static final StreamController<void> _vpnRevocations =
      StreamController<void>.broadcast();
  static bool _handlerInstalled = false;

  /// 用户在通知栏点了「断开」。
  static Stream<void> get disconnectRequests {
    _installHandler();
    return _disconnectRequests.stream;
  }

  /// 系统把这条 VPN 撤了：用户在系统设置里关掉，或者另一个 VPN 应用抢走了它。
  ///
  /// 那一刻 TUN 接口已经不在，fd 也跟着无效（见 `ShuVpnService.onRevoke`）——
  /// 但**服务本身还在**：纯代理模式与「VPN + 代理」组合下，本机代理还在用
  /// 同一条隧道，所以要不要停服务由 `ConnectionController` 判定。
  static Stream<void> get vpnRevocations {
    _installHandler();
    return _vpnRevocations.stream;
  }

  static void _installHandler() {
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'disconnectRequested':
          _disconnectRequests.add(null);
        case 'vpnRevoked':
          _vpnRevocations.add(null);
      }
      return null;
    });
  }

  /// 系统是否已经授予 VPN 权限。
  static Future<bool> get isPrepared async =>
      await _channel.invokeMethod<bool>('isPrepared') ?? false;

  /// 弹系统授权对话框。**需要一个前台页面**，否则原生侧会回 `no_activity`。
  static Future<bool> requestPermission() async =>
      await _channel.invokeMethod<bool>('requestPermission') ?? false;

  /// 起前台服务，**不**建 TUN。幂等。
  ///
  /// 纯代理（SOCKS5 / HTTP）模式下需要它：前台服务是「进程不会被后台回收」
  /// 的唯一凭据，而那两个服务器是 `dart:io` 的 `ServerSocket` —— 进程一走，
  /// 端口就没了，而界面还写着「已连接」。
  ///
  /// 服务类是 `VpnService` 的子类，所以纯代理模式也走得通（它只是不调
  /// `establish()`）—— 这正是两种模式共用一条通知、一个生命周期的原因：
  /// 只有 `VpnService` 能建 TUN，而平级的第二个服务只会多出一条通知。
  static Future<void> attachForeground() =>
      _channel.invokeMethod<void>('attachForeground');

  /// 停掉服务（关接口、撤掉通知栏）。
  ///
  /// 它撤的是**服务**，不是 TUN 接口 —— 两件事已经拆开了：接口的生死归
  /// [ShuAndroidVpnDevice.close]，服务的生死归「还有没有数据面需要它」（见
  /// `ConnectionController._detachForegroundIfIdle`）。
  static Future<void> detachForeground() => _channel.invokeMethod<void>('stop');

  /// 起服务、建 TUN，返回包设备；没有授权或建立失败时返回 `null`。
  ///
  /// [routes] 决定**哪些流量会被系统交给这条隧道**。它必须是网关资源表
  /// 展开后的网段（见 `vpn_routes.dart`），**不能是 `0.0.0.0/0`** —— 隧道
  /// 只会转发落在资源表里的包，其余的会被静默丢掉，全路由等于把所有流量
  /// 引向黑洞。
  ///
  /// 交给 TUN 的是资源表的**全部**网段，而不是「L3 背得动的那一部分」：
  /// aTrust 的 L3 数据面对 TCP 有一道 `enableTcpPrefL3` 的硬门，而 TUN 的
  /// 路由按目的地址分流、认不出协议。那些 TCP 由 Dart 侧的终结器在本机
  /// 接住（见 `connection_controller.dart` 的 `startVpn`），所以这一层不再
  /// 需要挑子集，也不设任何系统代理。
  ///
  /// [dnsServers] 是期望**走隧道**的 DNS（用户手填的，或网关下发且落在
  /// [routes] 内的）。原生侧一定会再追加底层网络那一组当兜底。
  static Future<ShuAndroidVpnDevice?> start({
    required String address,
    int prefixLength = 32,
    int mtu = 0,
    List<String> routes = const <String>[],
    List<String> dnsServers = const <String>[],
    String notificationTitle = 'ShuVPN',
    String disconnectLabel = '断开',
  }) async {
    final fd = await _channel.invokeMethod<int>('start', <String, Object?>{
      'address': address,
      'prefixLength': prefixLength,
      'mtu': mtu,
      'routes': routes,
      'dnsServers': dnsServers,
      'notificationTitle': notificationTitle,
      'disconnectLabel': disconnectLabel,
    });
    if (fd == null || fd < 0) {
      ShuLog.w(ShuLogTag.vpn, '原生侧没有返回可用的 TUN 描述符 · fd=$fd');
      return null;
    }
    return ShuAndroidVpnDevice.fromFd(fd);
  }

  /// 更新通知栏正文。
  ///
  /// [text] 就是那一行读数（见 `formatConnectionTelemetry`）。VPN 没在跑时
  /// 原生侧没有服务可更新，静默丢弃 —— 隧道拆掉的那一刻还可能有一两帧在
  /// 路上，那不是错误。
  static Future<void> updateNotification({required String text}) =>
      _channel.invokeMethod<void>('updateNotification', <String, Object?>{
        'text': text,
      });

  /// 系统有没有允许本应用发通知。
  ///
  /// 原生侧问的是 `NotificationManager.areNotificationsEnabled()`，不直接查
  /// `POST_NOTIFICATIONS`：前者把「Android 13+ 的运行期权限」与「更低版本里
  /// 用户在系统设置里关掉了通知」合成同一个答案 —— 而那个答案正是「隧道那
  /// 条常驻通知到底会不会出现」。
  static Future<bool> get isNotificationGranted async =>
      await _channel.invokeMethod<bool>('notificationGranted') ?? false;

  /// 弹系统的通知授权对话框，返回用户的选择。
  ///
  /// 已经允许、或系统没有这个对话框（Android 13 以下）时原生侧不弹、直接回
  /// 当前状态。对话框需要一个前台页面，后台调用会拿到 `no_activity`。
  static Future<bool> requestNotificationPermission() async =>
      await _channel.invokeMethod<bool>('requestNotificationPermission') ??
      false;
}

/// 把原生交过来的 TUN 描述符包成 [SangforPacketDevice]。
///
/// [close] 只关接口，**不**停服务。服务可能还被本机代理用着（纯代理模式、
/// 以及「VPN 关了但代理还开着」那一下），停它要等最后一个数据面也收工 ——
/// 而那件事只有 `ConnectionController` 知道。
class ShuAndroidVpnDevice implements SangforPacketDevice {
  ShuAndroidVpnDevice._(this._device);

  final FdPacketDevice _device;

  static Future<ShuAndroidVpnDevice> fromFd(int fd) async =>
      ShuAndroidVpnDevice._(await FdPacketDevice.fromFd(fd));

  @override
  Stream<Uint8List> get incoming => _device.incoming;

  @override
  bool get isClosed => _device.isClosed;

  @override
  Future<void> send(Uint8List packet) => _device.send(packet);

  @override
  Future<void> close() => _device.close();
}
