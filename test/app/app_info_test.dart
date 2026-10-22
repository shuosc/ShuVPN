// 应用版本号是**编译期注入**的（`FLUTTER_BUILD_NAME` / `FLUTTER_BUILD_NUMBER`，
// 由 Flutter 工具从 `pubspec.yaml` 的 `version:` 推出来），不再是这个仓库里手写
// 的另一份。这个文件盯的就是那条链子：写的东西和应用里显示的必须是同一个。
//
// 手工抄一份的失败方式是**安静的** —— 改了 pubspec 忘了改代码，表现只是关于页
// 上差一个号，没有报错、没有测试红。注入之后两处变一处，剩下的失败方式是「编译
// 时没注入」，而那会落到兜底值 `0.0.0` 上，读一下就看得见。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuvpn/app/app_info.dart';

/// `pubspec.yaml` 里 `version:` 那一行的值，如 `0.4.1+8`。
///
/// 不写成常量：那正是「另一份手抄」的毛病，会跟着每次发布过期。
String _pubspecVersion() {
  final line = File('pubspec.yaml')
      .readAsLinesSync()
      .firstWhere((line) => line.startsWith('version:'));
  return line.substring('version:'.length).trim();
}

void main() {
  group('应用版本号', () {
    test('版本名与构建号就是 pubspec.yaml 里的那两半', () {
      final declared = _pubspecVersion();
      final plus = declared.indexOf('+');
      expect(plus, greaterThan(0), reason: 'pubspec 的 version 形如 0.4.1+8');

      expect(ShuAppInfo.version, declared.substring(0, plus));
      expect(ShuAppInfo.buildLabel, declared.substring(plus + 1));
    });

    test('不是兜底值 —— 落到兜底上说明编译时没注入', () {
      expect(ShuAppInfo.version, isNot('0.0.0'));
      expect(ShuAppInfo.buildLabel, isNot('0'));
    });

    test('versionLabel 把两者拼成全角括号 —— 关于页与许可页用的是它', () {
      expect(
        ShuAppInfo.versionLabel,
        '${ShuAppInfo.version}（${ShuAppInfo.buildLabel}）',
      );
      expect(ShuAppInfo.versionLabel, contains('（'));
    });
  });
}
