import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuvpn/app/app.dart';
import 'package:shuvpn/app/theme.dart';
import 'package:shuvpn/core/settings/settings_store.dart';
import 'package:shuvpn/features/notifications/notifications_page.dart';
import 'package:shuvpn/features/services/coming_soon_page.dart';
import 'package:shuvpn/features/services/speedtest_page.dart';
import 'package:shuvpn/shell/floating_dock.dart';

import 'shu_update_stub.dart';

Future<void> _pumpApp(WidgetTester tester) async {
  tester.view.physicalSize = const Size(720, 1800);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final settings = await SettingsStore.load();
  settings.welcomeCompleted = true;
  await tester.pumpWidget(
    ShuVpnApp(settings: settings, updateClient: StubShuUpdateClient()),
  );
  await tester.pumpAndSettle();
}

Future<void> _openTab(WidgetTester tester, String label) async {
  await tester.tap(
    find.descendant(of: find.byType(FloatingDock), matching: find.text(label)),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('service entries keep their existing destinations', (
    tester,
  ) async {
    await _pumpApp(tester);
    await _openTab(tester, '服务');
    expect(find.text('网络测速'), findsOneWidget);
    expect(find.text('图书馆目录'), findsOneWidget);
    expect(find.byType(SwitchListTile), findsNothing);

    await tester.tap(find.text('网络测速'));
    await tester.pumpAndSettle();
    expect(find.byType(SpeedTestPage), findsOneWidget);
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('图书馆目录'));
    await tester.pumpAndSettle();
    expect(find.byType(ShuComingSoonPage), findsOneWidget);
    expect(find.text('未来版本提供服务'), findsOneWidget);
  });

  for (final tab in ['连接', '服务', '设置']) {
    testWidgets(
      '$tab opens tips and announcements and returns to the same page',
      (tester) async {
        await _pumpApp(tester);
        await _openTab(tester, tab);
        await tester.tap(find.byTooltip('通知'));
        await tester.pumpAndSettle();
        expect(find.byType(NotificationsPage), findsOneWidget);
        expect(find.byType(FloatingDock), findsNothing);
        expect(find.text('使用提示'), findsOneWidget);
        expect(find.text('系统公告'), findsOneWidget);
        expect(find.text('暂无使用提示').hitTestable(), findsOneWidget);
        await tester.tap(find.byTooltip('返回'));
        await tester.pumpAndSettle();
        expect(find.byType(NotificationsPage), findsNothing);
        expect(find.byType(FloatingDock), findsOneWidget);
        expect(find.text(tab), findsWidgets);
      },
    );
  }

  testWidgets('tabs switch by click and swipe with no content services', (
    tester,
  ) async {
    // No provider, HTTP client or repository is installed for this page.
    await tester.pumpWidget(
      MaterialApp(
        theme: buildShuTheme(Brightness.light),
        home: const NotificationsPage(),
      ),
    );
    expect(find.text('暂无使用提示').hitTestable(), findsOneWidget);
    await tester.tap(find.text('系统公告'));
    await tester.pumpAndSettle();
    expect(find.text('暂无系统公告').hitTestable(), findsOneWidget);
    expect(find.text('暂无使用提示').hitTestable(), findsNothing);

    await tester.drag(find.byType(TabBarView), const Offset(800, 0));
    await tester.pumpAndSettle();
    expect(find.text('暂无使用提示').hitTestable(), findsOneWidget);
    expect(find.byType(RefreshIndicator), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('下拉刷新'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final brightness in Brightness.values) {
    testWidgets(
      'notification placeholders fit a small ${brightness.name} window',
      (tester) async {
        tester.view.physicalSize = const Size(320, 320);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await tester.pumpWidget(
          MaterialApp(
            theme: buildShuTheme(brightness),
            home: const NotificationsPage(),
          ),
        );
        await tester.tap(find.text('系统公告'));
        await tester.pumpAndSettle();
        expect(find.text('暂无系统公告'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  }
}
