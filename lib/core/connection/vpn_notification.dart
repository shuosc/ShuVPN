import 'package:flutter/services.dart';

import '../logging/shu_log.dart';
import 'shu_android_vpn.dart';
import 'vpn_packet_log.dart';

/// 连接读数的一行：`↑ 1.2 MB/s · ↓ 340 KB/s · 时延 142 ms`。
///
/// 连接页的副标题与系统通知的正文共用这一个函数，两处于是永远是同一个
/// 字符串。它们会同时出现在用户眼前（通知栏与最上面那张抽屉），一边改了
/// 另一边没改，读起来就是两个不同的量。
///
/// [latencyMs] 为 `null` 时写 `—` 而**不是** `0 ms`：还没有一次成功的建连
/// 采样时，`0` 是一个测量结果，而这里根本没有测量。
String formatConnectionTelemetry({
  required double upBytesPerSecond,
  required double downBytesPerSecond,
  required double? latencyMs,
}) =>
    '↑ ${formatRate(upBytesPerSecond)}'
    ' · ↓ ${formatRate(downBytesPerSecond)}'
    ' · 时延 ${latencyMs == null ? '—' : '${latencyMs.round()} ms'}';

/// 把连接读数推到那条常驻通知。
///
/// ## 两种数据面共用同一条通知
///
/// 系统 VPN 与两个本机代理（SOCKS5 / HTTP）共用同一个前台服务，通知于是也
/// 只有一条：**纯代理模式下它同样在**，而且它比在 VPN 模式下更该在 —— 那条
/// 通知是「代理还活着」在系统里唯一的凭据（前台服务决定进程会不会被后台
/// 回收，而代理服务器是 `dart:io` 的 `ServerSocket`）。
///
/// ## 只有一行
///
/// 累计流量不进通知栏：这一行要在锁屏上一眼读完，而「这条隧道一共搬了
/// 多少」是连接页与日志该回答的事。
///
/// ## 为什么记住上一次
///
/// 采样定时器是 1 Hz 的，隧道空闲时它每秒产出的都是同一个「0 B/s」；平台
/// 通道每次是一轮编解码加一次 Binder 调用，原生侧每收一次就要重建一次
/// 通知。文本没变就什么都不做 —— 判断放在这一侧，因为文本就是在这里生成
/// 的，比穿过通道去问便宜。
///
/// 原生侧另有一道息屏门闸（见 `ShuVpnService.updateNotification`）。那是
/// 「屏幕黑着就不要打扰系统」，与这里的「内容没变就不要重复送」是两件事，
/// 两道都要有。
class ShuVpnNotification {
  /// 上一次推出去的正文；[reset] 之后是 `null`。
  String? _lastText;

  /// 忘掉上一次的内容。
  ///
  /// 每次建立隧道时调一次。不清的话，新隧道的第一个读数可能**恰好**与上
  /// 一条隧道留下的那个字符串相同（两条都在空闲时都是同一串 0），
  /// 那一帧会被当成重复帧丢掉，通知停在上一条隧道的数字上。
  void reset() => _lastText = null;

  /// 推一次；与上一次逐字相同时不发。
  ///
  /// 失败只记一行 DEBUG：通知是装饰性的，而调用它的是每秒一次的采样循环，
  /// 那里抛出去的异常会变成「一秒钟一条的未捕获错误」。
  Future<void> push({
    required double upBytesPerSecond,
    required double downBytesPerSecond,
    required double? latencyMs,
  }) async {
    final text = formatConnectionTelemetry(
      upBytesPerSecond: upBytesPerSecond,
      downBytesPerSecond: downBytesPerSecond,
      latencyMs: latencyMs,
    );
    if (text == _lastText) return;
    // 先记后发：失败的那一帧不重试。一秒后的下一次采样会带着新的数字再来，
    // 而隧道空闲时重试同一个字符串只是重复一次注定失败的调用。
    _lastText = text;
    try {
      await ShuAndroidVpn.updateNotification(text: text);
    } on MissingPluginException {
      // 桌面宿主与 widget 测试里没有这条通道。系统 VPN 本来就只有 Android 有。
    } on PlatformException catch (error) {
      ShuLog.d(ShuLogTag.vpn, '通知更新失败：${error.code}');
    }
  }
}
