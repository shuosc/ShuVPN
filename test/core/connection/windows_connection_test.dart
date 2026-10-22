import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_sangfor/flutter_sangfor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuvpn/core/connection/connection_controller.dart';
import 'package:shuvpn/core/connection/foreground_service.dart';
import 'package:shuvpn/core/connection/notification_permission.dart';
import 'package:shuvpn/core/connection/vpn_notification.dart';
import 'package:shuvpn/core/connection/vpn_permission.dart';
import 'package:shuvpn/core/settings/settings_store.dart';

class _SocketReader {
  _SocketReader(Socket socket) : _chunks = StreamIterator(socket);

  final StreamIterator<List<int>> _chunks;
  final _pending = <int>[];

  Future<List<int>> read(int length) async {
    while (_pending.length < length) {
      if (!await _chunks.moveNext().timeout(const Duration(seconds: 5))) {
        throw StateError('Socket closed before receiving $length bytes');
      }
      _pending.addAll(_chunks.current);
    }
    final result = _pending.sublist(0, length);
    _pending.removeRange(0, length);
    return result;
  }

  Future<void> close() => _chunks.cancel();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  group('platform connection settings', () {
    test('Windows defaults to two loopback proxies with no TUN', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final settings = await SettingsStore.load();
      addTearDown(settings.dispose);

      expect(settings.vpnEnabled, isFalse);
      expect(settings.httpProxyEnabled, isTrue);
      expect(settings.socksProxyEnabled, isTrue);
      expect(settings.httpListen.address, '127.0.0.1');
      expect(settings.socksListen.address, '127.0.0.1');
      expect(settings.httpPort, 3322);
      expect(settings.socksPort, 2233);
    });

    test('Android retains the system VPN defaults', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final settings = await SettingsStore.load();
      addTearDown(settings.dispose);

      expect(settings.vpnEnabled, isTrue);
      expect(settings.httpProxyEnabled, isFalse);
      expect(settings.socksProxyEnabled, isFalse);
    });

    test(
      'desktop ignores a stored TUN flag and preserves proxy choices',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{
          'settings.vpnEnabled': true,
          'settings.httpProxyEnabled': false,
          'settings.autoStartProxy': false,
        });
        final settings = await SettingsStore.load();
        addTearDown(settings.dispose);

        for (final platform in TargetPlatform.values) {
          if (platform == TargetPlatform.android) continue;
          debugDefaultTargetPlatformOverride = platform;
          expect(settings.vpnEnabled, isFalse, reason: platform.name);
        }
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        expect(settings.httpProxyEnabled, isFalse);
        expect(settings.socksProxyEnabled, isFalse);
        expect(settings.preferences.getBool('settings.vpnEnabled'), isTrue);
      },
    );
  });

  test(
    'desktop native capabilities ignore the UI target and Android channel',
    () async {
      // Widget tests default to an Android UI target even on Windows.
      // Native channel support must follow the actual desktop host.
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      const channel = MethodChannel('shuvpn/vpn');
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return true;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      const vpn = ShuVpnPermission();
      const notification = ShuNotificationPermission();
      expect(vpn.isSupported, isFalse);
      expect(notification.isSupported, isFalse);
      expect(await vpn.isPrepared(), isFalse);
      expect(await vpn.request(), isFalse);
      expect(await notification.isGranted(), isFalse);
      expect(await notification.request(), isFalse);

      final foreground = ShuForegroundService();
      expect(await foreground.attach(), isFalse);
      await foreground.releaseIfIdle(stillNeeded: false);
      await ShuVpnNotification().push(
        upBytesPerSecond: 0,
        downBytesPerSecond: 0,
        latencyMs: null,
      );

      SharedPreferences.setMockInitialValues(<String, Object>{});
      final settings = await SettingsStore.load();
      final connection = ConnectionController(
        settings,
        vpnPermission: vpn,
        notificationPermission: notification,
      );
      addTearDown(settings.dispose);
      addTearDown(connection.dispose);
      expect(await connection.ensureVpnPermission(), isTrue);
      expect(await connection.refreshVpnPermission(), isFalse);
      expect(await connection.requestVpnPermission(), isFalse);
      expect(await connection.refreshNotificationPermission(), isFalse);
      expect(await connection.requestNotificationPermission(), isFalse);
      expect(calls, isEmpty);
    },
    skip: Platform.isAndroid,
  );

  test('SOCKS5 forwards TCP on the desktop socket implementation', () async {
    final upstream = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final accepted = <Socket>[];
    upstream.listen((socket) {
      accepted.add(socket);
      socket.listen(socket.add, onError: (Object _) {});
    });
    addTearDown(() async {
      for (final socket in accepted) {
        socket.destroy();
      }
      await upstream.close();
    });

    String? targetHost;
    int? targetPort;
    final proxy = SangforSocks5Server(
      dialer: (host, port) async {
        targetHost = host;
        targetPort = port;
        return SocketTcpStream(
          await Socket.connect(InternetAddress.loopbackIPv4, upstream.port),
        );
      },
    );
    final port = await proxy.start();
    addTearDown(proxy.close);
    final client = await Socket.connect(InternetAddress.loopbackIPv4, port);
    final reader = _SocketReader(client);
    addTearDown(() async {
      client.destroy();
      await reader.close();
    });

    client.add(<int>[5, 1, 0]);
    await client.flush();
    expect(await reader.read(2), <int>[5, 0]);
    final host = ascii.encode('example.com');
    client.add(<int>[5, 1, 0, 3, host.length, ...host, 1, 187]);
    await client.flush();
    final reply = await reader.read(10);
    expect(reply.take(4), <int>[5, 0, 0, 1]);
    expect(targetHost, 'example.com');
    expect(targetPort, 443);

    final payload = utf8.encode('Windows SOCKS5 round trip');
    client.add(payload);
    await client.flush();
    expect(await reader.read(payload.length), payload);
  });
}
