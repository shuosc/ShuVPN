import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuvpn/app/shuyo_text_styles.dart';
import 'package:shuvpn/app/theme.dart';
import 'package:shuvpn/widgets/shu_app_bar.dart';

TextStyle _renderedStyle(WidgetTester tester, String text) =>
    (tester.renderObject<RenderParagraph>(find.text(text)).text as TextSpan)
        .style!;

void main() {
  for (final brightness in Brightness.values) {
    testWidgets(
      'Windows ${brightness.name} uses the same font fallback throughout the UI',
      (tester) async {
        final theme = buildShuTheme(brightness);
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(
              appBar: AppBar(title: const Text('标题 ShuVPN')),
              body: Column(
                children: [
                  const Text('默认正文 aTrust'),
                  Text('校园代理 HTTP', style: ShuYoTextStyles.body()),
                  FilledButton(onPressed: () {}, child: const Text('连接 VPN')),
                  Text(
                    '日志 TCP',
                    style: ShuYoTextStyles.meta().copyWith(
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),
            ),
          ),
        );

        for (final text in [
          '标题 ShuVPN',
          '默认正文 aTrust',
          '校园代理 HTTP',
          '连接 VPN',
        ]) {
          final style = _renderedStyle(tester, text);
          expect(style.fontFamily, 'Segoe UI', reason: text);
          expect(
            style.fontFamilyFallback,
            containsAllInOrder(['Microsoft YaHei UI', 'Microsoft YaHei']),
            reason: text,
          );
        }
        expect(_renderedStyle(tester, '日志 TCP').fontFamily, 'monospace');
        ScaffoldMessenger.of(tester.element(find.text('校园代理 HTTP')))
            .showSnackBar(const SnackBar(content: Text('连接提示 HTTP')));
        await tester.pumpAndSettle();
        final snackStyle = _renderedStyle(tester, '连接提示 HTTP');
        expect(snackStyle.fontFamily, 'Segoe UI');
        expect(snackStyle.fontFamilyFallback, contains('Microsoft YaHei UI'));
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  }

  testWidgets('Windows custom app bar inherits the UI font', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildShuTheme(Brightness.light),
        home: const Scaffold(appBar: ShuAppBar(title: '连接 HTTP')),
      ),
    );
    final style = _renderedStyle(tester, '连接 HTTP');
    expect(style.fontFamily, 'Segoe UI');
    expect(style.fontFamilyFallback, contains('Microsoft YaHei UI'));
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('Android retains the platform font instead of Windows families', (
    tester,
  ) async {
    final theme = buildShuTheme(Brightness.light);
    final platformTheme = ThemeData(useMaterial3: true);
    expect(
      theme.textTheme.bodyMedium!.fontFamily,
      platformTheme.textTheme.bodyMedium!.fontFamily,
    );
    expect(ShuYoTextStyles.body().fontFamily, isNull);
    expect(ShuYoTextStyles.headerTitle().fontFamilyFallback, isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
