import 'package:flutter/foundation.dart';

/// 检查更新在哪些平台上开着。
///
/// 只开 Android：发布产物只有 APK 一种。
///
/// 判据用 [defaultTargetPlatform] 而不是 `dart:io` 的 `Platform` —— 它可以在
/// debug 构建下被改写，这样 widget 测试既能量到「安卓上有这一行」，也能把平台
/// 换成别的来看它消失。`Platform` 没有这条通道。
abstract final class ShuUpdatePolicy {
  const ShuUpdatePolicy._();

  static bool get enabled => defaultTargetPlatform == TargetPlatform.android;
}
