import 'dart:io';

import 'shu_android_vpn.dart';

/// 「通知授权」这一层的接口。
///
/// 抽出来只为一件事：**测试**。widget 测试跑在桌面宿主上 ——
/// `Platform.isAndroid` 是 false、`shuvpn/vpn` 这条 channel 也不在，于是这
/// 一项永远落在「不支持」上，引导页清单里那一行根本长不出来。替换掉这一层，
/// 页面与 `ConnectionController` 都不用知道。
///
/// 与 [ShuVpnPermission] 是并列的两项，但性质不同：VPN 授权是**必需**的
/// （没有它就没有隧道），通知授权是**可选**的（没有它只是通知栏里少一条
/// 常驻通知）。引导页据此只把前者算进「继续」的门槛。
class ShuNotificationPermission {
  const ShuNotificationPermission();

  /// 这台设备有没有「通知授权」这回事。
  ///
  /// 只有 Android 有 —— 那条常驻通知本来就是 Android 前台服务的东西。
  bool get isSupported => Platform.isAndroid;

  /// 查一次当前状态：系统允许发通知就是 true。
  Future<bool> isGranted() => ShuAndroidVpn.isNotificationGranted;

  /// 弹系统授权对话框。
  ///
  /// 已经允许、或系统没有这个对话框（Android 13 以下）时原生侧直接回当前
  /// 状态、**不弹**（见 `ShuAndroidVpn.requestNotificationPermission`），
  /// 所以重复调用是安全的。
  Future<bool> request() => ShuAndroidVpn.requestNotificationPermission();
}
