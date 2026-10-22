# ShuVPN

[![Release](https://img.shields.io/github/v/release/shuosc/ShuVPN?color=1677ff&label=release)](https://github.com/shuosc/ShuVPN/releases)
[![Downloads](https://img.shields.io/github/downloads/shuosc/ShuVPN/total?color=1677ff&label=downloads)](https://github.com/shuosc/ShuVPN/releases)
[![License](https://img.shields.io/badge/license-AGPL--3.0-1677ff)](./LICENSE)
[![Flutter](https://img.shields.io/badge/Flutter-3.47.2-02569B?logo=flutter&logoColor=white)](https://flutter.dev)

专为 SHUer 设计的一站式校园VPN服务软件！

- 校园账户 账密/企业微信登录支持
- aTrust, Easyconnect, OpenVPN 多协议支持
- 按照各平台特性设计的多种接入方式,包含 HTTP 代理、SOCKS5 代理、Android VPN 服务等

## 安装

### Android
Android 版本可以打开 [release 页面](https://github.com/shuosc/ShuVPN/releases)下载。（依据设备差异，您可能需要在设置中允许「安装来自未知来源的应用」）

### Windows

已支持 Windows 10/11 x64，当前通过本机 HTTP 与 SOCKS5 代理访问校园资源，暂不提供 TUN 虚拟网卡。无需管理员权限或安装 VPN 驱动。

完整解压 Windows ZIP 后启动 `shuvpn.exe`，保留同目录的 DLL 与 `data` 文件夹。登录校园账户并连接后，在需要访问校园资源的浏览器或应用中配置：

- HTTP 代理：`127.0.0.1:3322`，支持 HTTP 与 HTTPS CONNECT。
- SOCKS5 代理：`127.0.0.1:2233`；访问内网域名时请选择通过代理解析 DNS。

这两项在 Windows 新安装时默认开启，实际地址与端口以「设置 → 网络连接」和连接页显示为准（端口占用时可能回退到其它端口）。应用不会自动修改 Windows 系统代理，也不会接管整机流量；最小化后代理继续运行，关闭窗口则退出并停止代理。Windows 暂不检查 APK 更新。

### MacOS/Linux
目前正在全力适配中，敬请期待。

### HarmoneyOS
> 特指 	HarmonyOS 5.0 及其未来版本的系统

目前正在全力适配中，敬请期待。

HarmonyOS 4.X 及其以前版本系统请使用 Android 版本安装包。

### iOS/iPadOS
目前暂时没有 ios/iPadOS 平台的适配计划。

如果您遇到了本应用中不符合预期的行为，欢迎先查看已有的 [Issues](https://github.com/shuosc/ShuVPN/issues)，也可以[新建 Issue](https://github.com/shuosc/ShuVPN/issues/new/choose) 反馈问题或提出建议。修复问题或新增功能时，欢迎提交 Pull Request。

## 编译说明

本应用使用 [Dart](https://dart.dev/) 和 [Flutter](https://flutter.dev/) 开发。

我们跟随 Flutter `stable` 渠道的最新版本，当前使用的编译版本为：

```shell
Flutter 3.47.2 • channel stable • https://github.com/flutter/flutter.git
Framework • revision d3b14c8769 (5 weeks ago) • 2026-08-26 16:07:51 -0700
Engine • hash 1cf1c4773fb941c4c74a7f8bb144a8837596c0f4 (revision a804b26164) (1 months ago) • 2026-08-26
18:46:13.000Z
Tools • Dart 3.13.2 • DevTools 2.60.0
```

为了构建本应用，您需要[下载](https://flutter.cn/docs/get-started/install)并安装 `Flutter SDK`，将 `flutter` 加入 PATH；

如果您正在为 `Android` 平台构建，需要安装 [Android Studio](https://developer.android.google.cn/studio)、配置 Android SDK 与 [Android Command Line Tools](https://developer.android.google.cn/studio)，并准备好可用的 Android 模拟器或真机设备。

如果为 Windows 构建，还需要安装 Visual Studio 的「使用 C++ 的桌面开发」工作负载、MSVC、CMake 与 Windows SDK。可以用 `flutter doctor -v` 检查。

<!-- 如果您正在为 `iOS/iPadOS` 平台构建，您还需要[安装并配置](https://apps.apple.com/app/id497799835) `Xcode`，并准备可用的 Simulator 或真机进行调试。 -->

确定配置正确后，在项目根目录执行：

```shell
flutter pub get
flutter devices
flutter run -d <device-id>
```

运行测试：

```shell
flutter test
```

### Windows 构建与打包

在 Windows PowerShell 中执行：

```powershell
flutter pub get
flutter run -d windows
# 编译 Release 并生成包含资源、插件和 MSVC 运行库的便携 ZIP：
./scripts/build_windows.ps1
```

可执行文件位于 `build/windows/x64/runner/Release/shuvpn.exe`，完整便携包位于 `build/windows/ShuVPN-windows-x64.zip`。也可单独执行 `flutter build windows --release`，随后用 `./scripts/build_windows.ps1 -SkipBuild` 打包。不要只复制 EXE。

三个 Sangfor 包统一引用 [preca-hoshino/flutter_sangfor](https://github.com/preca-hoshino/flutter_sangfor) 的 GitHub 默认分支，没有版本号或 `ref` 限制；实际提交由 `pubspec.lock` 记录。同步 fork 后，可执行以下命令更新：

```shell
flutter pub upgrade flutter_sangfor flutter_sangfor_atrust flutter_sangfor_easy_connect
```

本地 `pubspec_overrides.yaml` 如果包含 `path:` 会覆盖 GitHub 来源；验证发布构建前应先停用它，确保锁文件中的三个包均来自 Git。

### 平台相关代码

| 范围 | 位置与行为 |
| --- | --- |
| 桌面窗口、DPI、图标、打包 | [windows/](windows/)，原生窗口有最小尺寸与显示器工作区限制 |
| 连接方式默认值 | [settings_store.dart](lib/core/settings/settings_store.dart)，Windows 默认 HTTP/SOCKS5，Android 默认系统 VPN |
| 连接与系统 VPN | [connection_controller.dart](lib/core/connection/connection_controller.dart)、[shu_android_vpn.dart](lib/core/connection/shu_android_vpn.dart)，系统 VPN 仅 Android |
| 权限、前台服务、通知 | [vpn_permission.dart](lib/core/connection/vpn_permission.dart)、[notification_permission.dart](lib/core/connection/notification_permission.dart)、[foreground_service.dart](lib/core/connection/foreground_service.dart)、[vpn_notification.dart](lib/core/connection/vpn_notification.dart)，桌面不调用 Android 通道 |
| 更新 | [shu_update_policy.dart](lib/core/update/shu_update_policy.dart)，仅 Android 检查 APK 更新 |
| 引导与连接设置 | [welcome_page.dart](lib/features/onboarding/welcome_page.dart)、[connection_settings_page.dart](lib/features/settings/connection_settings_page.dart)，按平台能力显示可用功能 |

认证中的移动浏览器 User-Agent 与协议端平台标识用于兼容服务端认证流程，Windows 沿用现有约定；认证、公告、代理与持久化使用跨平台实现。

## 许可证

[AGPL-3.0](./LICENSE)

## 致谢

本项目参考研究了以下项目，感谢各位原作者。

- [zju-connect](https://github.com/Mythologyli/zju-connect) —— 提供了本项目的灵感，其 aTrust / EasyConnect 协议实现是登录与隧道链路的参考。
- [flutter_sangfor](https://github.com/TsinbeiLabs/flutter_sangfor) —— zju-connect 的 Flutter 库原生实现，本应用使用的协议栈。
- [shu-sso-poc](https://github.com/preca-hoshino/shu-sso-poc) —— 上海大学教务系统登录认证链路分析。
- [shu-otp-poc](https://github.com/preca-hoshino/shu-otp-poc) —— 上海大学 OTP 令牌系统定时获取的链路分析。
