import 'dart:async';

import 'package:flutter/gestures.dart';
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

Future<void> _connectPage(WidgetTester tester) async {
  _window(tester, const Size(1100, 760));
  final settings = await _settings()
    ..welcomeCompleted = true;
  await tester.pumpWidget(
    ShuVpnApp(settings: settings, updateClient: StubShuUpdateClient()),
  );
  await tester.pumpAndSettle();
}

double _scrimOpacity(WidgetTester tester) =>
    tester.widget<ColoredBox>(find.byKey(ConnectPage.scrimKey)).color.a;

double _drawerTop(WidgetTester tester) =>
    tester.getTopLeft(find.byKey(ConnectPage.grabberKey)).dy;

Future<void> _mouseDrag(WidgetTester tester, Offset start, double delta) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: start);
  await mouse.down(start);
  await mouse.moveBy(Offset(0, delta.sign * 20));
  await tester.pump(const Duration(milliseconds: 16));
  await mouse.moveBy(Offset(0, delta));
  await tester.pump(const Duration(milliseconds: 200));
  await mouse.up();
  await tester.pumpAndSettle();
  await mouse.removePointer();
}

void main() {
  testWidgets('Windows drawer follows a held mouse drag and snaps both ways', (
    tester,
  ) async {
    await _connectPage(tester);
    final grabber = find.byKey(ConnectPage.grabberKey);
    final collapsedTop = _drawerTop(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(grabber));
    await mouse.down(tester.getCenter(grabber));
    await mouse.moveBy(const Offset(0, -20));
    await tester.pump(const Duration(milliseconds: 16));
    await mouse.moveBy(const Offset(0, -45));
    await tester.pump(const Duration(milliseconds: 16));

    expect(_drawerTop(tester), lessThan(collapsedTop - 10));
    expect(_scrimOpacity(tester), inExclusiveRange(0, 0.34));
    await mouse.moveBy(const Offset(0, -200));
    await mouse.up();
    await tester.pumpAndSettle();
    await mouse.removePointer();
    final expandedTop = _drawerTop(tester);
    expect(expandedTop, lessThan(collapsedTop - 60));
    expect(_scrimOpacity(tester), closeTo(0.34, 0.001));

    await _mouseDrag(tester, tester.getCenter(grabber), 200);
    expect(_drawerTop(tester), closeTo(collapsedTop, 1));
    expect(_scrimOpacity(tester), 0);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets(
    'Windows wheel opens the drawer without scrolling its handle away',
    (tester) async {
      await _connectPage(tester);
      final collapsedTop = _drawerTop(tester);
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(find.byKey(ConnectPage.statusRowKey)),
          scrollDelta: const Offset(0, 120),
        ),
      );
      await tester.pumpAndSettle();
      final sheet = tester.widget<DraggableScrollableSheet>(
        find.byType(DraggableScrollableSheet),
      );
      expect(sheet.controller!.size, closeTo(sheet.maxChildSize, 0.001));
      expect(_drawerTop(tester), lessThan(collapsedTop - 60));
      expect(_scrimOpacity(tester), closeTo(0.34, 0.001));
      final scroll = tester.widget<SingleChildScrollView>(
        find.descendant(
          of: find.byType(DraggableScrollableSheet),
          matching: find.byType(SingleChildScrollView),
        ),
      );
      expect(scroll.controller!.offset, 0);
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(find.byKey(ConnectPage.statusRowKey)),
          scrollDelta: const Offset(0, -120),
        ),
      );
      await tester.pumpAndSettle();
      expect(_drawerTop(tester), closeTo(collapsedTop, 1));
      expect(_scrimOpacity(tester), 0);
      expect(scroll.controller!.offset, 0);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets('Windows mouse release snaps to the nearest drawer state', (
    tester,
  ) async {
    await _connectPage(tester);
    final grabber = find.byKey(ConnectPage.grabberKey);
    final collapsedTop = _drawerTop(tester);
    await tester.tap(grabber);
    await tester.pumpAndSettle();
    final expandedTop = _drawerTop(tester);
    final travel = collapsedTop - expandedTop;
    await tester.tap(grabber);
    await tester.pumpAndSettle();

    await _mouseDrag(tester, tester.getCenter(grabber), -travel * 0.25);
    expect(_drawerTop(tester), closeTo(collapsedTop, 1));
    expect(_scrimOpacity(tester), 0);
    await _mouseDrag(tester, tester.getCenter(grabber), -travel * 0.75);
    expect(_drawerTop(tester), closeTo(expandedTop, 1));
    expect(_scrimOpacity(tester), closeTo(0.34, 0.001));
    await _mouseDrag(tester, tester.getCenter(grabber), travel * 0.25);
    expect(_drawerTop(tester), closeTo(expandedTop, 1));
    await _mouseDrag(tester, tester.getCenter(grabber), travel * 0.75);
    expect(_drawerTop(tester), closeTo(collapsedTop, 1));
    expect(_scrimOpacity(tester), 0);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets(
    'Windows wheel scrolls overflowing content before closing and resets it',
    (tester) async {
      await _connectPage(tester);
      // 小窗口和大字体让内容超过抽屉的 90% 高度上限。
      tester.view.physicalSize = const Size(480, 320);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpAndSettle();
      final grabber = find.byKey(ConnectPage.grabberKey);
      final collapsedTop = _drawerTop(tester);
      await tester.tap(grabber);
      await tester.pumpAndSettle();
      final sheetFinder = find.byType(DraggableScrollableSheet);
      final sheet = tester.widget<DraggableScrollableSheet>(sheetFinder);
      final scrollFinder = find.descendant(
        of: sheetFinder,
        matching: find.byType(SingleChildScrollView),
      );
      final scroll = tester.widget<SingleChildScrollView>(scrollFinder);
      final controller = scroll.controller!;
      expect(controller.position.maxScrollExtent, greaterThan(10));

      Future<void> wheel(double delta) async {
        await tester.sendEventToBinding(
          PointerScrollEvent(
            position: tester.getCenter(scrollFinder),
            scrollDelta: Offset(0, delta),
          ),
        );
        await tester.pumpAndSettle();
      }

      final contentOffset = controller.position.maxScrollExtent / 2;
      await wheel(contentOffset);
      expect(controller.offset, closeTo(contentOffset, 0.1));
      expect(sheet.controller!.size, closeTo(sheet.maxChildSize, 0.001));
      expect(_scrimOpacity(tester), closeTo(0.34, 0.001));
      await wheel(-contentOffset);
      expect(controller.offset, 0);
      expect(sheet.controller!.size, closeTo(sheet.maxChildSize, 0.001));
      await wheel(-120);
      expect(_drawerTop(tester), closeTo(collapsedTop, 1));
      expect(_scrimOpacity(tester), 0);

      // 再次滚动内容后直接点遮罩收起：内部偏移必须清零，否则下次打开会
      // 丢失把手与状态行；这条路径实际验证 _resetContentScroll 的作用。
      await tester.tap(grabber);
      await tester.pumpAndSettle();
      await wheel(contentOffset);
      expect(controller.offset, greaterThan(0));
      final scrimRect = tester.getRect(find.byKey(ConnectPage.scrimKey));
      final viewportRect = tester.getRect(scrollFinder);
      await tester.tapAt(
        Offset(scrimRect.center.dx, (scrimRect.top + viewportRect.top) / 2),
      );
      await tester.pumpAndSettle();
      expect(controller.offset, 0);
      expect(_drawerTop(tester), closeTo(collapsedTop, 1));
      await tester.tap(grabber);
      await tester.pumpAndSettle();
      expect(controller.offset, 0);
      expect(sheet.controller!.size, closeTo(sheet.maxChildSize, 0.001));
      expect(_scrimOpacity(tester), closeTo(0.34, 0.001));
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets('Windows drawer stays stable after window size and DPI changes', (
    tester,
  ) async {
    await _connectPage(tester);
    final grabber = find.byKey(ConnectPage.grabberKey);
    await _mouseDrag(tester, tester.getCenter(grabber), -200);
    expect(_scrimOpacity(tester), closeTo(0.34, 0.001));
    tester.view.devicePixelRatio = 1.25;
    tester.view.physicalSize = const Size(600, 750);
    await tester.pumpAndSettle();
    final resizedTop = _drawerTop(tester);
    expect(_scrimOpacity(tester), 0);
    final sheet = tester.widget<DraggableScrollableSheet>(
      find.byType(DraggableScrollableSheet),
    );
    expect(sheet.controller!.size, closeTo(sheet.minChildSize, 0.001));
    await tester.pump(const Duration(milliseconds: 500));
    expect(_drawerTop(tester), closeTo(resizedTop, 0.1));
    await _mouseDrag(tester, tester.getCenter(grabber), -200);
    expect(sheet.controller!.size, closeTo(sheet.maxChildSize, 0.001));
    expect(_scrimOpacity(tester), closeTo(0.34, 0.001));
    final expandedTop = _drawerTop(tester);
    await tester.pump(const Duration(milliseconds: 500));
    expect(_drawerTop(tester), closeTo(expandedTop, 0.1));

    // 遮罩在新窗口坐标里仍能收回抽屉，收回后把命中测试还给主页面。
    await tester.tapAt(const Offset(240, 140));
    await tester.pumpAndSettle();
    expect(_drawerTop(tester), closeTo(resizedTop, 1));
    expect(_scrimOpacity(tester), 0);
    final scrimHitTest = tester.widget<IgnorePointer>(
      find
          .ancestor(
            of: find.byKey(ConnectPage.scrimKey),
            matching: find.byType(IgnorePointer),
          )
          .first,
    );
    expect(scrimHitTest.ignoring, isTrue);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

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
