// 「前台服务」这一格的离线单测。
//
// 两种数据面共用同一个服务、同一条常驻通知（系统 VPN 与两个本机代理），
// 所以这一格错了的后果是其中一种模式的保护静默消失：VPN 关着、只开 SOCKS5
// 时进程被系统回收 → 端口没了，而界面还写着「已连接」。
//
// 要钉死的三件事：attach 是幂等的、releaseIfIdle 只在没人需要时真撤、
// 原生侧把服务拉起来过这件事能被记下来（否则它永远撤不掉）。

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuvpn/core/connection/foreground_service.dart';
import 'package:shuvpn/core/logging/shu_log.dart';

/// 把「这台设备有没有前台服务」报成 true。
///
/// 测试跑在桌面宿主上，真的那一层会说「没有」—— 而那正是它在这里最没用的
/// 答案。形状与 `welcome_test.dart` 里的 `_FakeVpnPermission` 一样。
class _FakeForegroundService extends ShuForegroundService {
  @override
  bool get isSupported => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('shuvpn/vpn');
  final calls = <String>[];

  setUp(() {
    calls.clear();
    ShuLog.instance.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    ShuLog.instance.clear();
  });

  group('attach', () {
    test('第一次真的起服务，再来一次什么都不做', () async {
      final foreground = _FakeForegroundService();
      expect(foreground.attached, isFalse);

      expect(await foreground.attach(), isTrue);
      expect(foreground.attached, isTrue);
      // 已经在跑时返回 false：调用方据此知道「不用再推第一帧通知内容」。
      expect(await foreground.attach(), isFalse);

      expect(calls, <String>['attachForeground']);
    });

    test('撤掉之后还能再起来', () async {
      final foreground = _FakeForegroundService();
      await foreground.attach();
      await foreground.releaseIfIdle(stillNeeded: false);
      expect(await foreground.attach(), isTrue);

      expect(calls, <String>['attachForeground', 'stop', 'attachForeground']);
    });

    test('这台设备没有前台服务这回事时，什么都不调也不抛', () async {
      // 真的那一层：桌面宿主上 `Platform.isAndroid` 是 false。
      final foreground = ShuForegroundService();

      expect(await foreground.attach(), isFalse);
      expect(foreground.attached, isFalse);
      expect(calls, isEmpty);
    });
  });

  group('releaseIfIdle', () {
    test('还有数据面需要它时不动它', () async {
      final foreground = _FakeForegroundService();
      await foreground.attach();

      await foreground.releaseIfIdle(stillNeeded: true);

      expect(foreground.attached, isTrue);
      expect(calls, <String>['attachForeground']);
    });

    test('没人需要了就撤，并且记下已经撤了', () async {
      final foreground = _FakeForegroundService();
      await foreground.attach();

      await foreground.releaseIfIdle(stillNeeded: false);
      expect(foreground.attached, isFalse);
      expect(calls, <String>['attachForeground', 'stop']);

      // 撤第二次不该再调一次原生：服务本来就不在。
      await foreground.releaseIfIdle(stillNeeded: false);
      expect(calls, <String>['attachForeground', 'stop']);
    });

    test('没起来过时什么都不做', () async {
      final foreground = _FakeForegroundService();
      await foreground.releaseIfIdle(stillNeeded: false);

      expect(calls, isEmpty);
    });
  });

  group('markAttached', () {
    test('原生侧拉起来的服务同样会被撤掉', () async {
      // `ShuAndroidVpn.start` 的第一步就是起服务（只有 `VpnService` 能建
      // TUN），所以建 TUN 那条路上服务是原生拉起来的 —— 不记这一笔，后面
      // 「没人需要了就撤掉」会以为服务没起来，于是它永远撤不掉。
      final foreground = _FakeForegroundService();
      foreground.markAttached();

      expect(foreground.attached, isTrue);
      await foreground.releaseIfIdle(stillNeeded: false);
      expect(foreground.attached, isFalse);
      expect(calls, <String>['stop']);
    });
  });
}
