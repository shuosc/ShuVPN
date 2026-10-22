// 设置的模式版本与迁移。
//
// 这一层只在**升级**那一刻跑一次，而那时没有人看着 —— 迁移写错的表现是
// 「用户升完级打开，某个设置莫名其妙变了」，从现象上完全追不到这里。所以
// 每一版迁移的「保留什么、删掉什么」都在这里钉死。

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuvpn/core/settings/settings_schema.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('v1 → v2', () {
    test('清掉「资源外直连」—— 那个能力整个撤掉了', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        ShuSettingsSchema.versionKey: 1,
        'settings.proxyDirectFallback': true,
      });
      final prefs = await SharedPreferences.getInstance();
      final store = ShuSettingsStore(prefs);

      expect(store.needsMigration, isTrue);
      await store.migrateIfNeeded();

      expect(prefs.containsKey('settings.proxyDirectFallback'), isFalse);
      expect(store.storedVersion, ShuSettingsSchema.current);
    });

    test('保留代理与 VPN 的设置，不丢用户改过的值', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        ShuSettingsSchema.versionKey: 1,
        'settings.autoStartProxy': true,
        'settings.socksPort': 1080,
        'settings.socksListen': '0.0.0.0',
        'settings.vpnMtu': 1280,
        'settings.vpnDns': '10.10.0.116',
        'settings.server': 'other.example',
      });
      final prefs = await SharedPreferences.getInstance();
      await ShuSettingsStore(prefs).migrateIfNeeded();

      expect(prefs.getBool('settings.autoStartProxy'), isTrue);
      expect(prefs.getInt('settings.socksPort'), 1080);
      expect(prefs.getString('settings.socksListen'), '0.0.0.0');
      expect(prefs.getInt('settings.vpnMtu'), 1280);
      expect(prefs.getString('settings.vpnDns'), '10.10.0.116');
      expect(prefs.getString('settings.server'), 'other.example');
    });

    test('不碰 auth. 开头的键 —— 那是凭据，不是设置', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        ShuSettingsSchema.versionKey: 1,
        'auth.session': '{"cookies":[]}',
      });
      final prefs = await SharedPreferences.getInstance();
      await ShuSettingsStore(prefs).migrateIfNeeded();

      expect(prefs.getString('auth.session'), '{"cookies":[]}');
    });

    test('幂等：已经是当前版本时什么都不做', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        ShuSettingsSchema.versionKey: ShuSettingsSchema.current,
        // 手工塞一个「上一版残留」的键：它不该被这一轮的迁移碰到。
        'settings.proxyDirectFallback': true,
      });
      final prefs = await SharedPreferences.getInstance();
      final store = ShuSettingsStore(prefs);

      expect(store.needsMigration, isFalse);
      await store.migrateIfNeeded();

      expect(prefs.containsKey('settings.proxyDirectFallback'), isTrue);
    });

    test('v0（没有版本号）会连着跑完 v1 与 v2，但不会跑 v3', () async {
      // v0 不等于「很老的版本」—— 它同时意味着一次干净安装，而引导不能
      // 在新装用户的第一次启动时就被标成已完成。判据是 `from >= 1`。
      SharedPreferences.setMockInitialValues(<String, Object>{
        'settings.lastServer': 'old.example',
        'settings.proxyDirectFallback': true,
      });
      final prefs = await SharedPreferences.getInstance();
      await ShuSettingsStore(prefs).migrateIfNeeded();

      expect(prefs.containsKey('settings.lastServer'), isFalse);
      expect(prefs.containsKey('settings.proxyDirectFallback'), isFalse);
      expect(prefs.getBool('settings.welcomeCompleted'), isNull);
      expect(
        prefs.getInt(ShuSettingsSchema.versionKey),
        ShuSettingsSchema.current,
      );
    });
  });

  group('v3 → v4', () {
    test('只清掉「TCP 走 L3」实验开关', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        ShuSettingsSchema.versionKey: 3,
        'settings.vpnTcpOverL3': true,
      });
      final prefs = await SharedPreferences.getInstance();
      await ShuSettingsStore(prefs).migrateIfNeeded();

      expect(prefs.containsKey('settings.vpnTcpOverL3'), isFalse);
      expect(
        prefs.getInt(ShuSettingsSchema.versionKey),
        ShuSettingsSchema.current,
      );
    });

    test('本机代理与 VPN 的设置原样保留', () async {
      // ⚠️ 这一条是防回退的：HTTP 通道不再当系统 VPN 的 TCP 出口（那一步改由
      // 本机终结器接管），但它本身仍然是一条独立的代理通道 —— 把它的设置
      // 当成「不再行为」一并清掉，等于把用户配过的监听地址与端口静默重置。
      SharedPreferences.setMockInitialValues(<String, Object>{
        ShuSettingsSchema.versionKey: 3,
        'settings.httpProxyEnabled': true,
        'settings.httpListen': '0.0.0.0',
        'settings.httpPort': 3322,
        'settings.socksPort': 1080,
        'settings.socksListen': '192.168.99.144',
        'settings.autoStartProxy': true,
        'settings.vpnMtu': 1280,
      });
      final prefs = await SharedPreferences.getInstance();
      await ShuSettingsStore(prefs).migrateIfNeeded();

      expect(prefs.getBool('settings.httpProxyEnabled'), isTrue);
      expect(prefs.getString('settings.httpListen'), '0.0.0.0');
      expect(prefs.getInt('settings.httpPort'), 3322);
      expect(prefs.getInt('settings.socksPort'), 1080);
      expect(prefs.getString('settings.socksListen'), '192.168.99.144');
      expect(prefs.getBool('settings.autoStartProxy'), isTrue);
      expect(prefs.getInt('settings.vpnMtu'), 1280);
    });
  });

  group('v2 → v3', () {
    test('装过旧版本的设备视为已完成引导，旧设置保留', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        ShuSettingsSchema.versionKey: 2,
        'settings.socksPort': 2233,
      });
      final prefs = await SharedPreferences.getInstance();
      await ShuSettingsStore(prefs).migrateIfNeeded();

      expect(prefs.getBool('settings.welcomeCompleted'), isTrue);
      expect(prefs.getInt('settings.socksPort'), 2233);
      expect(
        prefs.getInt(ShuSettingsSchema.versionKey),
        ShuSettingsSchema.current,
      );
    });

    test('干净安装什么都没写 —— 引导该出现', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final prefs = await SharedPreferences.getInstance();
      await ShuSettingsStore(prefs).migrateIfNeeded();

      expect(prefs.getBool('settings.welcomeCompleted'), isNull);
      expect(prefs.getInt(ShuSettingsSchema.versionKey), isNotNull);
    });
  });
}
