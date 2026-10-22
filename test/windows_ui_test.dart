import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuvpn/app/app.dart';
import 'package:shuvpn/app/theme.dart';
import 'package:shuvpn/core/auth/wecom_auth_service.dart';
import 'package:shuvpn/core/connection/connection_controller.dart';
import 'package:shuvpn/core/settings/settings_store.dart';
import 'package:shuvpn/features/account/wecom_scan_page.dart';
import 'package:shuvpn/features/connect/connect_page.dart';
import 'package:shuvpn/features/settings/connection_settings_page.dart';
import 'package:shuvpn/features/settings/experimental_settings_page.dart';
import 'package:shuvpn/features/settings/permission_info_page.dart';
import 'package:shuvpn/shell/floating_dock.dart';

import 'shu_update_stub.dart';

class _WaitingWeComService extends ShuWeComAuthService {
  final _session = Completer<ShuWeComQrSession>();

  @override
  Future<ShuWeComQrSession> startQrSession() => _session.future;
}

void _window(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<SettingsStore> _settings() async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  return SettingsStore.load();
}

Future<void> _settingsPage(
  WidgetTester tester,
  SettingsStore settings,
  Widget page,
) async {
  _window(tester, const Size(480, 600));
  final connection = ConnectionController(settings);
  addTearDown(connection.dispose);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<SettingsStore>.value(value: settings),
        ChangeNotifierProvider<ConnectionController>.value(value: connection),
      ],
      child: MaterialApp(theme: buildShuTheme(Brightness.light), home: page),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Windows connection settings expose usable proxy controls', (
    tester,
  ) async {
    final settings = await _settings();
    await _settingsPage(tester, settings, const ShuConnectionSettingsPage());

    expect(find.text('启用 HTTP 代理'), findsOneWidget);
    expect(find.text('启用 SOCKS5 代理'), findsOneWidget);
    final switches = tester.widgetList<SwitchListTile>(
      find.byType(SwitchListTile),
    );
    expect(switches, hasLength(2));
    expect(switches.every((tile) => tile.value), isTrue);
    for (final label in ['Android VPN 服务', '启用 VPN 服务', 'MTU', 'DNS']) {
      expect(find.text(label), findsNothing);
    }
    await tester.scrollUntilVisible(find.textContaining('不会自动修改系统代理'), 200);
    expect(find.textContaining('不会自动修改系统代理'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('Windows experimental settings omit Android TCP controls', (
    tester,
  ) async {
    await _settingsPage(
      tester,
      await _settings(),
      const ShuExperimentalSettingsPage(),
    );
    expect(find.text('新用户引导'), findsOneWidget);
    expect(find.text('系统 VPN'), findsNothing);
    expect(find.text('TCP 接收窗口缩放'), findsNothing);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('Windows permission information matches proxy operation', (
    tester,
  ) async {
    _window(tester, const Size(480, 600));
    await tester.pumpWidget(
      MaterialApp(
        theme: buildShuTheme(Brightness.light),
        home: const PermissionInfoPage(),
      ),
    );
    expect(find.text('VPN 服务'), findsNothing);
    expect(find.text('通知'), findsNothing);
    expect(find.text('网络访问'), findsOneWidget);
    expect(find.textContaining('无需管理员权限'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('Windows onboarding proceeds to login in a small window', (
    tester,
  ) async {
    _window(tester, const Size(480, 600));
    await tester.pumpWidget(
      ShuVpnApp(
        settings: await _settings(),
        updateClient: StubShuUpdateClient(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('继续'));
    await tester.pumpAndSettle();
    expect(find.text('使用本机代理'), findsOneWidget);
    expect(find.textContaining('不会自动修改系统代理'), findsOneWidget);
    await tester.tap(find.text('继续'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('去登录'));
    await tester.pumpAndSettle();
    expect(find.text('用户名/学号'), findsOneWidget);
    expect(find.text('密码'), findsOneWidget);
    expect(find.byType(FloatingDock), findsNothing);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('Windows QR login scrolls in a short window', (tester) async {
    _window(tester, const Size(480, 480));
    await tester.pumpWidget(
      MaterialApp(
        theme: buildShuTheme(Brightness.light),
        home: WeComScanPage(authService: _WaitingWeComService()),
      ),
    );
    expect(find.textContaining('扫描电脑上的二维码'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(find.text('尝试打开本机企业微信'), 160);
    final openButton = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, '尝试打开本机企业微信'),
    );
    expect(openButton.onPressed, isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  for (final size in [const Size(480, 600), const Size(1100, 760)]) {
    testWidgets('Windows shell works at ${size.width} x ${size.height}', (
      tester,
    ) async {
      _window(tester, size);
      final settings = await _settings()
        ..welcomeCompleted = true;
      await tester.pumpWidget(
        ShuVpnApp(settings: settings, updateClient: StubShuUpdateClient()),
      );
      await tester.pumpAndSettle();
      final grabber = find.byKey(ConnectPage.grabberKey);
      final collapsedTop = tester.getTopLeft(grabber).dy;
      await tester.tap(grabber);
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(grabber).dy, lessThan(collapsedTop));
      await tester.tap(grabber);
      await tester.pumpAndSettle();

      Future<void> openTab(String label) async {
        await tester.tap(
          find.descendant(
            of: find.byType(FloatingDock),
            matching: find.text(label),
          ),
        );
        await tester.pumpAndSettle();
      }

      await openTab('设置');
      expect(find.text('HTTP 与 SOCKS5 本机代理'), findsOneWidget);
      await openTab('服务');
      await tester.tap(find.text('网络测速'));
      await tester.pumpAndSettle();
      expect(find.text('开始测速'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
  }
}
