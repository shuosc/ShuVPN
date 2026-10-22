import 'dart:ffi';

/// The ABI of the running app, rather than the host CPU or UI platform.
/// A universal APK runs one ABI; an emulated Windows x64 app remains x64.
enum ShuReleaseTarget {
  androidArm64('android', 'arm64-v8a', 'apk'),
  androidArm('android', 'armeabi-v7a', 'apk'),
  androidX64('android', 'x86_64', 'apk'),
  windowsX64('windows', 'x64', 'zip'),
  windowsArm64('windows', 'arm64', 'zip');

  const ShuReleaseTarget(this.platform, this.architecture, this.extension);

  final String platform;
  final String architecture;
  final String extension;

  String assetName(String version) =>
      'ShuVPN-v$version-$platform-$architecture.$extension';

  static ShuReleaseTarget? fromAbi(Abi abi) => switch (abi) {
    Abi.androidArm64 => androidArm64,
    Abi.androidArm => androidArm,
    Abi.androidX64 => androidX64,
    Abi.windowsX64 => windowsX64,
    Abi.windowsArm64 => windowsArm64,
    _ => null,
  };

  static ShuReleaseTarget? get current => fromAbi(Abi.current());
}
