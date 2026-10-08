// 系统通知正文的离线单测。
//
// 这一层是纯逻辑加一次平台通道调用：格式化与「内容没变就不送」的判断都不
// 需要隧道、设备或 Android。要钉死的是两件事 —— 通知栏与连接页上那串读数
// 逐字相同，以及 1 Hz 的空闲采样不会变成每秒一次的通知重建。

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuvpn/core/connection/vpn_notification.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('shuvpn/vpn');
  final calls = <MethodCall>[];

  void mockChannel() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
  }

  setUp(() {
    calls.clear();
    mockChannel();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('formatConnectionTelemetry', () {
    test('上下行与时延合成一行，量纲与日志一致', () {
      expect(
        formatConnectionTelemetry(
          upBytesPerSecond: 2048,
          downBytesPerSecond: 3 * 1024 * 1024,
          latencyMs: 142,
        ),
        '↑ 2.0 KB/s · ↓ 3.0 MB/s · 时延 142 ms',
      );
    });

    test('还没有建连样本时写 — 而不是 0 ms', () {
      expect(
        formatConnectionTelemetry(
          upBytesPerSecond: 0,
          downBytesPerSecond: 0,
          latencyMs: null,
        ),
        '↑ 0 B/s · ↓ 0 B/s · 时延 —',
      );
    });

    test('时延四舍五入到整毫秒', () {
      expect(
        formatConnectionTelemetry(
          upBytesPerSecond: 0,
          downBytesPerSecond: 0,
          latencyMs: 142.4,
        ),
        endsWith('时延 142 ms'),
      );
      expect(
        formatConnectionTelemetry(
          upBytesPerSecond: 0,
          downBytesPerSecond: 0,
          latencyMs: 142.6,
        ),
        endsWith('时延 143 ms'),
      );
    });
  });

  group('ShuVpnNotification', () {
    Future<void> push(
      ShuVpnNotification notification, {
      double up = 1024,
      double down = 0,
      double? latency = 100,
    }) => notification.push(
      upBytesPerSecond: up,
      downBytesPerSecond: down,
      latencyMs: latency,
    );

    test('第一次推就穿过通道，只有正文一项参数', () async {
      await push(ShuVpnNotification(), latency: null);

      expect(calls, hasLength(1));
      expect(calls.single.method, 'updateNotification');
      expect(calls.single.arguments, <String, Object?>{
        'text': '↑ 1.0 KB/s · ↓ 0 B/s · 时延 —',
      });
    });

    test('读数完全没变就不推', () async {
      final notification = ShuVpnNotification();
      await push(notification);
      await push(notification);
      await push(notification);

      expect(calls, hasLength(1));
    });

    test('三个数里任何一个变了都推', () async {
      final notification = ShuVpnNotification();
      await push(notification);
      await push(notification, latency: 140);
      await push(notification, latency: 140, down: 4096);

      expect(calls, hasLength(3));
    });

    test('reset 之后同一个读数还会再推一次', () async {
      final notification = ShuVpnNotification();
      await push(notification);
      await push(notification);
      notification.reset();
      await push(notification);

      expect(calls, hasLength(2));
    });

    test('没有这条通道时（桌面宿主与 widget 测试）不抛', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);

      await expectLater(push(ShuVpnNotification()), completes);
    });
  });
}
