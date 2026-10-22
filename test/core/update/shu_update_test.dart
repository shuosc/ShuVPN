// 更新检查的纯逻辑与弹窗。
//
// 网络那一半没有可测的分支，所以这里只喂 JSON、只读返回值 —— 不发请求，
// 也不碰 GitHub。

import 'dart:ffi';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuvpn/app/app_info.dart';
import 'package:shuvpn/core/update/shu_update_client.dart';
import 'package:shuvpn/core/update/shu_release_target.dart';
import 'package:shuvpn/core/update/shu_update_info.dart';
import 'package:shuvpn/widgets/shu_update_prompt.dart';

Map<String, Object?> _release({
  Object? tag = 'v0.4.0',
  Object? assets,
  String htmlUrl = 'https://github.com/shuosc/ShuVPN/releases/tag/v0.4.0',
}) {
  return <String, Object?>{
    'tag_name': tag,
    'html_url': htmlUrl,
    'published_at': '2026-10-03T19:12:25Z',
    'assets':
        assets ??
        <Map<String, Object?>>[
          <String, Object?>{
            'name': 'ShuVPN-v0.4.0-android-arm64-v8a.apk',
            'browser_download_url':
                'https://github.com/shuosc/ShuVPN/releases/download/'
                'v0.4.0/ShuVPN-v0.4.0-android-arm64-v8a.apk',
          },
          <String, Object?>{
            'name': 'ShuVPN-v0.4.0-android-arm64-v8a.apk.sha256',
            'browser_download_url':
                'https://github.com/shuosc/ShuVPN/releases/download/'
                'v0.4.0/ShuVPN-v0.4.0-android-arm64-v8a.apk.sha256',
          },
        ],
  };
}

void main() {
  group('compareShuVersions', () {
    test('ignores the tag prefix and the build number', () {
      expect(compareShuVersions('v0.3.0', '0.3.0'), 0);
      expect(compareShuVersions('0.3.0+4', '0.3.0'), 0);
    });

    test('compares each part as a number, not as text', () {
      expect(compareShuVersions('0.3.10', '0.3.9'), greaterThan(0));
      expect(compareShuVersions('0.9.0', '0.10.0'), lessThan(0));
      expect(compareShuVersions('1.0.0', '0.99.99'), greaterThan(0));
    });

    test('treats a missing part as zero', () {
      expect(compareShuVersions('0.4', '0.4.0'), 0);
      expect(compareShuVersions('0.4.1', '0.4'), greaterThan(0));
    });

    test('orders a pre-release before the release it belongs to', () {
      expect(compareShuVersions('0.4.0', '0.4.0-beta.1'), greaterThan(0));
      expect(
        compareShuVersions('0.4.0-beta.2', '0.4.0-beta.1'),
        greaterThan(0),
      );
      expect(compareShuVersions('0.4.0-beta.1', '0.4.0'), lessThan(0));
    });
  });

  group('updateInfoFromReleaseJson', () {
    test('reads the apk link and skips the checksum file', () {
      final update = updateInfoFromReleaseJson(
        _release(),
        currentVersion: '0.3.0',
        target: ShuReleaseTarget.androidArm64,
      );

      expect(update, isNotNull);
      expect(update!.latestVersion, '0.4.0');
      expect(
        update.downloadUrl,
        endsWith('ShuVPN-v0.4.0-android-arm64-v8a.apk'),
      );
      expect(update.hasDownloadUrl, isTrue);
      expect(update.targetUrl, update.downloadUrl);
      expect(update.publishedAt, DateTime.utc(2026, 10, 3, 19, 12, 25));
    });

    test('falls back to the release page when no apk is published', () {
      final update = updateInfoFromReleaseJson(
        _release(assets: <Object?>[]),
        currentVersion: '0.3.0',
      );

      expect(update, isNotNull);
      expect(update!.hasDownloadUrl, isFalse);
      expect(update.targetUrl, endsWith('/releases/tag/v0.4.0'));
    });

    test('returns null when the tag is not newer', () {
      expect(
        updateInfoFromReleaseJson(
          _release(tag: 'v0.3.0'),
          currentVersion: '0.3.0',
        ),
        isNull,
      );
      expect(
        updateInfoFromReleaseJson(
          _release(tag: 'v0.2.0'),
          currentVersion: '0.3.0',
        ),
        isNull,
      );
    });

    test('returns null when the tag is missing or unreadable', () {
      expect(
        updateInfoFromReleaseJson(_release(tag: null), currentVersion: '0.3.0'),
        isNull,
      );
      expect(
        updateInfoFromReleaseJson(
          _release(tag: 'latest'),
          currentVersion: '0.3.0',
        ),
        isNull,
      );
    });
  });

  group('release architecture selection', () {
    Map<String, Object?> asset(String name, {String? url}) => {
      'name': name,
      'state': 'uploaded',
      'browser_download_url':
          url ??
          'https://github.com/shuosc/ShuVPN/releases/download/v0.4.0/$name',
    };

    test('maps actual runtime ABIs independently of the UI platform', () {
      final mapping = {
        Abi.androidArm: ShuReleaseTarget.androidArm,
        Abi.androidArm64: ShuReleaseTarget.androidArm64,
        Abi.androidX64: ShuReleaseTarget.androidX64,
        Abi.windowsX64: ShuReleaseTarget.windowsX64,
        Abi.windowsArm64: ShuReleaseTarget.windowsArm64,
      };
      for (final entry in mapping.entries) {
        expect(ShuReleaseTarget.fromAbi(entry.key), entry.value);
      }
      expect(ShuReleaseTarget.fromAbi(Abi.linuxX64), isNull);
      expect(ShuReleaseTarget.current, ShuReleaseTarget.fromAbi(Abi.current()));
    });

    for (final target in ShuReleaseTarget.values) {
      test('${target.name} selects its own asset from a mixed release', () {
        final name = target.assetName('0.4.0');
        final update = updateInfoFromReleaseJson(
          _release(
            assets: [
              asset('ShuVPN-v0.4.0-android-universal.apk'),
              asset('ShuVPN-v0.4.0.apk'),
              for (final other in ShuReleaseTarget.values.reversed)
                asset(other.assetName('0.4.0')),
              asset('$name.sha256'),
            ],
          ),
          currentVersion: '0.3.0',
          target: target,
        )!;
        expect(update.downloadUrl, endsWith('/$name'));
        expect(update.downloadUrl, isNot(contains('universal')));
      });
    }

    test(
      'missing ABI does not pick universal, legacy or another architecture',
      () {
        final update = updateInfoFromReleaseJson(
          _release(
            assets: [
              asset('ShuVPN-v0.4.0-android-universal.apk'),
              asset('ShuVPN-v0.4.0.apk'),
              asset(ShuReleaseTarget.androidArm64.assetName('0.4.0')),
              asset(ShuReleaseTarget.windowsArm64.assetName('0.4.0')),
            ],
          ),
          currentVersion: '0.3.0',
          target: ShuReleaseTarget.androidX64,
        )!;
        expect(update.hasDownloadUrl, isFalse);
        expect(update.targetUrl, endsWith('/releases/tag/v0.4.0'));
      },
    );

    test('unknown ABI never receives a download', () {
      expect(
        updateInfoFromReleaseJson(
          _release(),
          currentVersion: '0.3.0',
        )!.hasDownloadUrl,
        isFalse,
      );
    });

    test('rejects stale versions, incomplete uploads and mismatched URLs', () {
      const target = ShuReleaseTarget.androidArm64;
      final name = target.assetName('0.4.0');
      for (final invalid in [
        asset(target.assetName('0.3.0')),
        {...asset(name), 'state': 'new'},
        asset(name, url: 'https://example.com/$name'),
        asset(
          name,
          url: 'https://github.com/other/ShuVPN/releases/download/v0.4.0/$name',
        ),
        asset(
          name,
          url:
              'https://github.com/shuosc/ShuVPN/releases/download/v0.3.0/$name',
        ),
        asset('$name.sha256'),
      ]) {
        expect(
          pickReleaseDownloadUrl(
            [invalid],
            version: '0.4.0',
            tag: 'v0.4.0',
            target: target,
          ),
          isEmpty,
        );
      }
    });
  });

  group('showShuUpdatePrompt', () {
    Future<List<bool>> openPrompt(
      WidgetTester tester,
      ShuUpdateInfo update,
    ) async {
      final answers = <bool>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async => answers.add(
                await showShuUpdatePrompt(context, update: update),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      return answers;
    }

    testWidgets('shows both versions and offers the download', (tester) async {
      final answers = await openPrompt(
        tester,
        const ShuUpdateInfo(
          latestVersion: '99.0.0',
          downloadUrl: 'https://example.com/ShuVPN.apk',
          releasePageUrl: 'https://example.com/releases',
        ),
      );

      expect(find.text('发现新版本'), findsOneWidget);
      expect(find.text('当前版本：${ShuAppInfo.version}'), findsOneWidget);
      expect(find.text('最新版本：99.0.0'), findsOneWidget);

      await tester.tap(find.text('更新'));
      await tester.pumpAndSettle();
      expect(answers, <bool>[true]);
    });

    testWidgets('drops the download button when there is no link', (
      tester,
    ) async {
      final answers = await openPrompt(
        tester,
        const ShuUpdateInfo(
          latestVersion: '99.0.0',
          downloadUrl: '',
          releasePageUrl: 'https://example.com/releases',
        ),
      );

      expect(find.text('更新'), findsNothing);

      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();
      expect(answers, <bool>[false]);
    });
  });
}
