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
Windows 版本可以打开 [release 页面](https://github.com/shuosc/ShuVPN/releases)下载，支持 Windows 10/11 x64、arm64。完整解压后运行 `shuvpn.exe`，无需安装或管理员权限。（请保留解压后的全部文件）

> 目前 Windows 版本仅支持代理连接，需要手动配置系统或应用代理。使用时请保持应用运行，最小化不影响连接，关闭窗口则会断开连接。

### macOS
macOS 版本提供 Intel（x64）和 Apple Silicon（arm64）两种 ZIP 包，需要 macOS 12 或更新版本。下载后解压，将 `ShuVPN.app` 放入「应用程序」即可。

应用未使用 Apple 开发者证书签名或公证，仅保留运行所需的本地临时签名。首次打开时可能需要在「系统设置 → 隐私与安全性」中允许打开。

### Linux
Linux 版本覆盖 Flutter 支持的 x64、arm64，分别提供 DEB 和 RPM 包。请在 [release 页面](https://github.com/shuosc/ShuVPN/releases)选择对应架构和发行版的安装包，安装后从应用菜单启动 ShuVPN。

### HarmoneyOS
> 特指 	HarmonyOS 5.0 及其未来版本的系统

目前正在全力适配中，敬请期待。

HarmonyOS 4.X 及其以前版本系统请使用 Android 版本安装包。

### iOS/iPadOS
iOS/iPadOS 版本提供 arm64 无签名 IPA，需要 iOS/iPadOS 15 或更新版本。安装前需要自行签名。


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

如果您正在为 `Windows` 平台构建，需要安装 [Visual Studio](https://visualstudio.microsoft.com/zh-hans/) 并勾选「使用 C++ 的桌面开发」工作负载，确保已安装 MSVC、CMake 与 Windows SDK。您可以执行 `flutter doctor -v` 检查开发环境。

如果您正在为 `iOS/iPadOS` 或 `macOS` 平台构建，需要使用 macOS 并[安装和配置 Xcode](https://apps.apple.com/app/id497799835)。

如果您正在为 `Linux` 平台构建，需要与目标架构一致的 x64 或 arm64 Debian/Ubuntu 环境。CI 使用 Ubuntu 24.04；构建与打包依赖可通过以下命令安装：

```sh
sudo apt-get update
sudo apt-get install --no-install-recommends -y \
  clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev \
  libstdc++-12-dev rpm binutils dpkg-dev desktop-file-utils \
  git curl unzip xz-utils libglu1-mesa
```

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

开发约定：[LLM 使用政策](LLM_POLICY.md)

## 许可证

[AGPL-3.0](./LICENSE)

## 致谢

本项目参考研究了以下项目，感谢各位原作者。

- [zju-connect](https://github.com/Mythologyli/zju-connect) —— 提供了本项目的灵感，其 aTrust / EasyConnect 协议实现是登录与隧道链路的参考。
- [flutter_sangfor](https://github.com/TsinbeiLabs/flutter_sangfor) —— zju-connect 的 Flutter 库原生实现，本应用使用的协议栈。
- [shu-sso-poc](https://github.com/preca-hoshino/shu-sso-poc) —— 上海大学教务系统登录认证链路分析。
- [shu-otp-poc](https://github.com/preca-hoshino/shu-otp-poc) —— 上海大学 OTP 令牌系统定时获取的链路分析。
