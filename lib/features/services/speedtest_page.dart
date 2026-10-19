import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/shuyo_text_styles.dart';
import '../../app/theme.dart';
import '../../core/connection/connection_controller.dart';
import '../../core/logging/shu_log.dart';
import '../../core/settings/settings_store.dart';
import '../../core/speedtest/shu_speedtest.dart';
import '../../core/speedtest/shu_speedtest_service.dart';
import '../../widgets/shu_app_bar.dart';
import '../../widgets/shu_surfaces.dart';

/// 顶栏底部进度条的高度。槽位常驻，起停时整页不上下跳。
const double _progressBarHeight = 3;

/// 读数块往表盘里叠进去的高度。
///
/// 表盘是 270° 开口朝下，正下方那一块本来就是空的，把数字与单位挪进去
/// 正好落在这个缺口里。
const double _readoutLift = 22;

/// 「服务 → 网络测速」。
///
/// ## 版式学的是 Ookla
///
/// 这一页只回答一个问题：现在这条网络有多快。屏幕上从上到下是：一颗表盘、
/// 一行读数（数字 + 单位）、一行延迟与抖动（`PING` 后面是空闲 / 下载 /
/// 上传三个值，后两个用上下箭头标识）、两行客户端 IP（地址族与地址 / 国旗与运营商）、
/// 两个大数（下行 / 上行）。按钮
/// 只有一个，跑起来之后锁住 —— 一轮测速是有始有终的，中途那个数不构成
/// 结果。
///
/// 表盘照 Ookla：刻度固定为 0 / 5 / 10 / 50 / 100 / 250 / 500 / 750 / 1k，
/// 在弧上**等距**排开；指针位置按同一张表分段线性换算，所以针停在哪两个
/// 刻度之间，读数就一定落在对应的两个数之间。表盘中心不放字：数字贴着
/// 圆心会被指针压住，字号也只能跟着半径缩。弧长与指针表达的是「在量程的
/// 哪一段」。
///
/// 上下行一律两位小数（`160.06`）：末位跳动不会改变数字宽度，测完之后也
/// 不会从 `160.06` 突然缩成 `160`。延迟与抖动沿用测速站的 `format()`。
///
/// ## 完成之后回到待测
///
/// 测完不留「测速完成」这种状态：读数回到 `0.00 Mbps`、表盘归 0、按钮回到
/// 「开始测速」，这一页看起来和刚进来一样。唯一留下的是时延、抖动、下载、
/// 上传四个数和客户端 IP —— 那是用户这一轮真正要看的东西。页面被路由销毁
/// 也不丢，记在 [ShuSpeedTestHistory]。
///
/// ## 与三个数据面无关
///
/// 这一页只问 `ConnectionController` 要一个东西：隧道内的拨号器。有隧道
/// 就走隧道（内部临时起一条回环代理，端口随机、用完就关），没隧道就直连；
/// 两种都不要求先打开 HTTP 代理、SOCK55 或系统 VPN 中的任何一个。页脚只写
/// 测速站是哪一个，不再报这一轮走了哪条 —— 那是调试信息，不是这一页要回答
/// 的问题。
class SpeedTestPage extends StatefulWidget {
  const SpeedTestPage({super.key, this.runner});

  /// 可注入只为测试：真实现每次要打十几秒网络，而 widget 测试只关心读数
  /// 怎么画。
  final ShuSpeedTestRunner? runner;

  @override
  State<SpeedTestPage> createState() => _SpeedTestPageState();
}

class _SpeedTestPageState extends State<SpeedTestPage> {
  /// 当前这一轮（或最近一轮）的通道。为 null 时还没开始过。
  ShuSpeedTestRunner? _runner;

  ShuSpeedTestProgress _progress = const ShuSpeedTestProgress();
  ShuSpeedTestReport? _report;
  String? _error;
  bool _running = false;
  late bool _preferIpv6;

  ShuSpeedTestServer get _preferredServer =>
      _preferIpv6 ? ShuSpeedTestServer.shuIpv6 : ShuSpeedTestServer.shu;

  @override
  void initState() {
    super.initState();
    _report = ShuSpeedTestHistory.last;
    _preferIpv6 = context.read<SettingsStore>().speedtestPreferIpv6;
  }

  @override
  void dispose() {
    _runner?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final readout = _readout;

    return Scaffold(
      appBar: ShuAppBar(
        title: '网络测速',
        onBack: () => Navigator.of(context).pop(),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: PopupMenuButton<bool>(
              tooltip: '连接偏好',
              enabled: !_running,
              position: PopupMenuPosition.under,
              icon: const Icon(Icons.more_vert),
              onSelected: (preferIpv6) {
                context.read<SettingsStore>().speedtestPreferIpv6 = preferIpv6;
                setState(() => _preferIpv6 = preferIpv6);
              },
              itemBuilder: (context) => [
                CheckedPopupMenuItem<bool>(
                  value: true,
                  checked: _preferIpv6,
                  child: const Text('优先 IPv6'),
                ),
                CheckedPopupMenuItem<bool>(
                  value: false,
                  checked: !_preferIpv6,
                  child: const Text('优先 IPv4'),
                ),
              ],
            ),
          ),
        ],
        bottomHeight: _progressBarHeight,
        bottom: _SpeedProgressBar(
          // 失败时进度停在中途那个数上没有意义，直接收掉。
          phase: _error == null ? _phase : ShuSpeedTestPhase.idle,
          progress: _progress.progress,
          color: _phaseColor(colors),
          reduceMotion: reduceMotion,
        ),
      ),
      body: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            // 先减掉左右页边距，再取上限。
            //
            // 顺序不能反：`SingleChildScrollView` 的 padding 是在这个
            // `SizedBox` **外面**加的，直接用 `constraints.maxWidth` 当内容
            // 宽度会多出两倍的页边距，窄屏上就是一条横向溢出。
            final available = math.max(
              0.0,
              constraints.maxWidth - ShuSpacing.page * 2,
            );
            // 桌面上限宽：表盘再大就只是把留白放大。
            final width = math.min(available, 520.0);
            final gauge = math.min(width, 296.0);
            return Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(
                  ShuSpacing.page,
                  8,
                  ShuSpacing.page,
                  24,
                ),
                child: SizedBox(
                  width: width,
                  child: Column(
                    children: [
                      // 读数往表盘下部开口里挪一段：数字贴着圆弧下面看起来
                      // 是另一块内容，插进去之后才是同一个仪表的读数。叠放比
                      // 单纯缩小间距更贴近 Ookla 的构图，也不会把下面那行
                      // 指标往下推太多。
                      SizedBox(
                        height: gauge + _SpeedReadout.height - _readoutLift,
                        child: Stack(
                          alignment: Alignment.topCenter,
                          children: [
                            _SpeedGauge(
                              size: gauge,
                              progress: _arcProgress,
                              color: _phaseColor(colors),
                              reduceMotion: reduceMotion,
                              trackColor: colors.surfaceMuted,
                              tickColor: colors.borderStrong,
                              labelColor: colors.textTertiary,
                            ),
                            Positioned(
                              top: gauge - _readoutLift,
                              left: 0,
                              right: 0,
                              child: _SpeedReadout(
                                readout: readout,
                                valueColor: _error == null
                                    ? colors.textPrimary
                                    : colors.textMuted,
                                iconColor: _phaseColor(colors),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'PING',
                              style: ShuYoTextStyles.meta(
                                color: colors.textTertiary,
                              ).copyWith(letterSpacing: 0.6),
                            ),
                            const SizedBox(width: 8),
                            // 第一个数就是空闲时延，`PING` 已经说明了它是什么；
                            // 后两个挂上下行图标，一行不用再写「下载 / 上传」。
                            _LatencyValue(value: _pingMs),
                            const SizedBox(width: 12),
                            _LatencyValue(
                              value: _downloadLatencyMs,
                              icon: Icons.south_rounded,
                              iconColor: colors.accent,
                            ),
                            const SizedBox(width: 12),
                            _LatencyValue(
                              value: _uploadLatencyMs,
                              icon: Icons.north_rounded,
                              iconColor: colors.accentAlt,
                            ),
                            const SizedBox(width: 12),
                            Text(
                              '·',
                              style: ShuYoTextStyles.meta(
                                color: colors.textMuted,
                              ),
                            ),
                            const SizedBox(width: 12),
                            _Metric(label: '抖动', value: _jitterMs),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      _SpeedIpInfo(
                        version: _clientIpVersion,
                        address: _clientIp ?? '--',
                        isp: _clientIsp,
                        countryCode: _clientCountryCode,
                      ),
                      const SizedBox(height: 20),
                      ShuCard(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        child: Row(
                          children: [
                            Expanded(
                              child: _SpeedStat(
                                icon: Icons.south_rounded,
                                label: '下载',
                                color: colors.accent,
                                value: _formatReadout(_downloadMbps),
                              ),
                            ),
                            Container(
                              width: 1,
                              height: 46,
                              color: colors.border,
                            ),
                            Expanded(
                              child: _SpeedStat(
                                icon: Icons.north_rounded,
                                label: '上传',
                                color: colors.accentAlt,
                                value: _formatReadout(_uploadMbps),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),
                      SizedBox(
                        width: double.infinity,
                        height: 52,
                        child: FilledButton.icon(
                          // 测量中锁住：一轮测速是有始有终的，中途那个数不构成
                          // 结果。要离开就退出页面，`dispose` 会取消。
                          onPressed: _running ? null : _start,
                          // 圆角矩形，不是胶囊：这一页只有它一颗按钮，压扁的
                          // 药丸形状会把整页的重量压低。
                          style: FilledButton.styleFrom(
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(
                                ShuRadii.tile,
                              ),
                            ),
                          ),
                          icon: Icon(
                            _running
                                ? Icons.hourglass_top_rounded
                                : Icons.play_arrow_rounded,
                            size: 20,
                          ),
                          label: Text(_buttonLabel),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        '测速支持：上海大学测速站 speedtest.cc.shu.edu.cn',
                        textAlign: TextAlign.center,
                        style: ShuYoTextStyles.meta(color: colors.textMuted),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ 状态

  Future<void> _start() async {
    final injected = widget.runner;
    final dialer = injected == null
        ? context.read<ConnectionController>().tunnelDialer
        : null;
    final runner =
        injected ??
        ShuSpeedTestService(server: _preferredServer, dialer: dialer);

    setState(() {
      _runner = runner;
      _running = true;
      _error = null;
      _report = null;
      _progress = const ShuSpeedTestProgress(phase: ShuSpeedTestPhase.ping);
    });

    void onUpdate(ShuSpeedTestProgress progress) {
      if (!mounted) return;
      setState(() => _progress = progress);
    }

    try {
      ShuSpeedTestReport report;
      try {
        report = await runner.run(onUpdate: onUpdate);
      } on ShuSpeedTestException catch (error) {
        final initialConnectionFailed =
            _progress.phase == ShuSpeedTestPhase.ping &&
            _progress.progress == 0;
        if (injected != null ||
            !_preferIpv6 ||
            !initialConnectionFailed ||
            (error.kind != ShuSpeedTestFailure.unreachable &&
                error.kind != ShuSpeedTestFailure.timeout)) {
          rethrow;
        }
        if (!mounted) return;
        final fallback = ShuSpeedTestService(
          server: ShuSpeedTestServer.shu,
          dialer: dialer,
        );
        setState(() {
          _runner = fallback;
          _progress = const ShuSpeedTestProgress(phase: ShuSpeedTestPhase.ping);
        });
        report = await fallback.run(onUpdate: onUpdate);
      }
      if (!mounted) return;
      ShuSpeedTestHistory.record(report);
      setState(() {
        _report = report;
        _running = false;
      });
    } on ShuSpeedTestException catch (error) {
      if (!mounted) return;
      if (error.kind == ShuSpeedTestFailure.cancelled) {
        setState(() {
          _running = false;
          _progress = const ShuSpeedTestProgress();
          // 取消不是一次结果：回到上一轮，没有就完全回到待测。
          _report = ShuSpeedTestHistory.last;
        });
        return;
      }
      setState(() {
        _running = false;
        _error = error.message;
      });
      _showFailure(error.message, hint: _hintFor(error));
    } on Object catch (error) {
      // 通道抛出的任何东西都要落到「可重试」，否则按钮会永远停在「停止」。
      if (!mounted) return;
      ShuLog.w(ShuLogTag.speedtest, '未预期错误 · $error');
      final message = '测速失败：$error';
      setState(() {
        _running = false;
        _error = message;
      });
      _showFailure(message);
    }
  }

  /// 底部的错误条。
  ///
  /// `SnackBarBehavior.fixed` 会铺满屏幕宽度，从底部长出来；用它而不是在
  /// 页面里插一段说明，是因为测速失败时读数区已经缩成 `—`，再在按钮上方
  /// 加一块文字会把整页高度顶变，下次进来又缩回去。
  void _showFailure(String message, {String? hint}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.fixed,
          duration: const Duration(seconds: 5),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(message),
              if (hint != null) ...[
                const SizedBox(height: 2),
                Text(hint, style: const TextStyle(fontSize: 12.5)),
              ],
            ],
          ),
        ),
      );
  }

  /// 连不上与超时对用户是同一件事：此刻到不了测速站。
  ///
  /// 新站支持公网访问；连不上时提示用户检查当前网络。
  static String? _hintFor(ShuSpeedTestException error) {
    return switch (error.kind) {
      ShuSpeedTestFailure.unreachable ||
      ShuSpeedTestFailure.timeout => '请检查网络连接后重试。',
      _ => null,
    };
  }

  double? get _pingMs => _report?.pingMs ?? _progress.pingMs;
  double? get _jitterMs => _report?.jitterMs ?? _progress.jitterMs;
  double? get _downloadLatencyMs =>
      _report?.downloadLatencyMs ?? _progress.downloadLatencyMs;
  double? get _uploadLatencyMs =>
      _report?.uploadLatencyMs ?? _progress.uploadLatencyMs;
  double? get _downloadMbps => _report?.downloadMbps ?? _progress.downloadMbps;
  double? get _uploadMbps => _report?.uploadMbps ?? _progress.uploadMbps;
  String? get _clientIp => _report?.clientIp ?? _progress.clientIp;
  String? get _clientIsp => _report?.clientIsp ?? _progress.clientIsp;
  String? get _clientCountryCode =>
      _report?.clientCountryCode ?? _progress.clientCountryCode;

  String get _clientIpVersion {
    final address = _clientIp?.trim();
    if (address == null || address.isEmpty) return 'IP';
    final ip = address.split(RegExp(r'[\s(]')).first;
    if (ip.contains(':')) return 'IPV6';
    if (ip.contains('.')) return 'IPV4';
    return 'IP';
  }

  /// 两格大数的文本。
  ///
  /// 一律固定两位小数：测量中末位跳动不会改变数字宽度，测完之后也不会从
  /// `160.06` 突然缩成 `160`，两组读数逐位对得上。
  String? _formatReadout(double? value) {
    if (value == null) return null;
    return value.toStringAsFixed(2);
  }

  /// 有结果就是完成了，不管最后一条进度回调报的是哪个阶段。
  ///
  /// 真实现会补一条 `done`；但页面不该依赖这一点 —— 通道的实现换一个，
  /// 读数就不该停在「正在上传」。
  ShuSpeedTestPhase get _phase =>
      _report != null ? ShuSpeedTestPhase.done : _progress.phase;

  /// 指针当前指示的速度。
  ///
  /// 只有下载与上传阶段有值 —— 完成后归 0，表盘等下一轮；结果本身留在
  /// 下载 / 上传两格里，不靠在表盘上停住一个指针来表达。
  double get _liveMbps {
    if (_error != null) return 0;
    return switch (_phase) {
      ShuSpeedTestPhase.download ||
      ShuSpeedTestPhase.upload => _progress.speedMbps,
      _ => 0,
    };
  }

  double get _arcProgress {
    // 时延阶段没有速率可画；完成之后也回 0，等下一轮。
    if (_phase == ShuSpeedTestPhase.ping) return 0;
    return _gaugeAmount(_liveMbps);
  }

  Color _phaseColor(ShuYoColors colors) {
    if (_error != null) return colors.danger;
    return switch (_phase) {
      ShuSpeedTestPhase.ping => colors.textTertiary,
      ShuSpeedTestPhase.download => colors.accent,
      ShuSpeedTestPhase.upload => colors.accentAlt,
      // 完成后与待测同色：表盘归零，看起来就像刚进来。
      ShuSpeedTestPhase.done || ShuSpeedTestPhase.idle => colors.textMuted,
    };
  }

  ({String value, String unit, IconData? icon}) get _readout {
    if (_error != null) return (value: '—', unit: '', icon: null);
    return switch (_phase) {
      // 时延读数不上表盘，也不占读数位：那一刻量的是往返，不是速率。
      ShuSpeedTestPhase.ping => (value: '', unit: '', icon: null),
      ShuSpeedTestPhase.download => (
        value: _liveText(_progress.speedMbps),
        unit: 'Mbps',
        icon: Icons.south_rounded,
      ),
      ShuSpeedTestPhase.upload => (
        value: _liveText(_progress.speedMbps),
        unit: 'Mbps',
        icon: Icons.north_rounded,
      ),
      // 完成后回到待测：四个结果留在下面的格子里。
      ShuSpeedTestPhase.done ||
      ShuSpeedTestPhase.idle => (value: '0.00', unit: 'Mbps', icon: null),
    };
  }

  /// 测量进行中的读数，固定两位小数。
  static String _liveText(double value) => value.toStringAsFixed(2);

  String get _buttonLabel {
    if (_running) return '测速中';
    if (_error != null) return '重试';
    return '开始测速';
  }
}

/// 把 Mbps 换成表盘上的 0..1 位置。
///
/// 表盘刻度：数值与文字。
///
/// 最后一个写 `1k` 而不是 `1000`：弧尾只剩几个像素，四位数字会被旁边的
/// `750` 挤在一起。
const List<(double, String)> _gaugeLabels = <(double, String)>[
  (0, '0'),
  (5, '5'),
  (10, '10'),
  (50, '50'),
  (100, '100'),
  (250, '250'),
  (500, '500'),
  (750, '750'),
  (1000, '1k'),
];

/// 把 Mbps 换成表盘上的 0..1 位置。
///
/// 刻度在弧上是**等距**的，但每一段跨的数值不同（0→5 与 500→750 占一样的
/// 弧长），所以这里按刻度表分段线性插值：先找到读数落在哪两个刻度之间，
/// 再把这一段里的比例铺到对应的一格弧上。超过 1 Gbps 时指针停在弧尾。
///
/// 等距而不是按数值线性：线性量程下 10 Mbps 与 100 Mbps 都会挤在最左边
/// 一成里，而这两个数恰恰是「慢链路」与「正常链路」的分界。
/// 分段而不是单一对数：刻度是固定的，指针必须与刻度对得上 —— 单一曲线
/// 会让指针停在两个刻度之间偏一截，读数与刻度互相打架。
double _gaugeAmount(double mbps) {
  if (mbps <= 0) return 0;
  final segments = _gaugeLabels.length - 1;
  if (mbps >= _gaugeLabels.last.$1) return 1;
  for (var index = 0; index < segments; index++) {
    final low = _gaugeLabels[index].$1;
    final high = _gaugeLabels[index + 1].$1;
    if (mbps <= high) {
      final fraction = (mbps - low) / (high - low);
      return (index + fraction) / segments;
    }
  }
  return 1;
}

/// 顶栏底下那根进度条。
///
/// 三个状态：时延阶段是**不定进度** —— 那一刻还不知道要打几个往返，来回
/// 刮动的条正好表达「在跑、但无法预估」；下载与上传按**本阶段剩余时间**
/// 走，条到头这一阶段也就结束了；待测、完成、失败时不画。
///
/// 不写数字：顶栏没有位置，读数区也不该再塞一行字。剩余多少由条自己表达。
///
/// 槽位由 [ShuAppBar.bottom] 常驻占住 3 像素，所以这里不画的时候也只能
/// 返回一个空盒子，而不是让页面塌一节。
class _SpeedProgressBar extends StatefulWidget {
  const _SpeedProgressBar({
    required this.phase,
    required this.progress,
    required this.color,
    required this.reduceMotion,
  });

  final ShuSpeedTestPhase phase;
  final double progress;
  final Color color;
  final bool reduceMotion;

  @override
  State<_SpeedProgressBar> createState() => _SpeedProgressBarState();
}

class _SpeedProgressBarState extends State<_SpeedProgressBar> {
  bool _retracting = false;
  Color? _retractColor;

  @override
  void didUpdateWidget(covariant _SpeedProgressBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.reduceMotion) {
      _retracting = false;
    } else if (oldWidget.phase != widget.phase) {
      _retracting =
          (oldWidget.phase == ShuSpeedTestPhase.download &&
              widget.phase == ShuSpeedTestPhase.upload) ||
          (oldWidget.phase == ShuSpeedTestPhase.upload &&
              widget.phase == ShuSpeedTestPhase.done);
      if (_retracting) _retractColor = oldWidget.color;
    }
  }

  @override
  Widget build(BuildContext context) {
    return switch (widget.phase) {
      ShuSpeedTestPhase.ping => LinearProgressIndicator(
        minHeight: _progressBarHeight,
        backgroundColor: Colors.transparent,
        color: widget.color,
      ),
      ShuSpeedTestPhase.download ||
      ShuSpeedTestPhase.upload ||
      ShuSpeedTestPhase.done => TweenAnimationBuilder<double>(
        // 采样约每 50 ms 到一帧；补间稍长一点，让条在两帧之间继续移动。
        // 阶段切换先向 0 缩回；上传的进度在缩完后再从 0 向前走。
        tween: Tween<double>(
          begin: 0,
          end: _retracting || widget.phase == ShuSpeedTestPhase.done
              ? 0
              : widget.progress.clamp(0.0, 1.0),
        ),
        duration: widget.reduceMotion
            ? Duration.zero
            : _retracting || widget.phase == ShuSpeedTestPhase.done
            ? const Duration(milliseconds: 320)
            : const Duration(milliseconds: 120),
        curve: Curves.linear,
        onEnd: () {
          if (_retracting && mounted) setState(() => _retracting = false);
        },
        builder: (context, value, _) => LinearProgressIndicator(
          value: value,
          minHeight: _progressBarHeight,
          backgroundColor: Colors.transparent,
          color: _retracting ? _retractColor : widget.color,
        ),
      ),
      ShuSpeedTestPhase.idle => const SizedBox.shrink(),
    };
  }
}

/// 中间那颗表盘。
///
/// 弧度与指针是 270°：开口朝下，与 Ookla 一样。弧上等距标出 Ookla 的那组
/// 刻度（0 / 5 / 10 / 50 / 100 / 250 / 500 / 750 / 1k），把「指针在哪儿」
/// 换算成「大概多少 Mbps」；读数与单位由表盘下方的 [_SpeedReadout] 排版 ——
/// 数字贴圆心会被指针压住，字号也只能跟着半径缩。
///
/// 补间时长分两档：读数往上跳时只给 50 毫秒（跟着 50 毫秒一次的采样走，
/// 数字看起来在抖），回落时给 320 毫秒 —— 阶段收尾那一下要看得见指针从
/// 弧上退回去，太快就成了硬切。
class _SpeedGauge extends StatefulWidget {
  const _SpeedGauge({
    required this.size,
    required this.progress,
    required this.color,
    required this.reduceMotion,
    required this.trackColor,
    required this.tickColor,
    required this.labelColor,
  });

  final double size;
  final double progress;
  final Color color;
  final bool reduceMotion;
  final Color trackColor;
  final Color tickColor;
  final Color labelColor;

  @override
  State<_SpeedGauge> createState() => _SpeedGaugeState();
}

class _SpeedGaugeState extends State<_SpeedGauge> {
  /// 上一帧的目标值。用它判断这一帧是往上跳还是往回落。
  double _previous = 0;

  @override
  Widget build(BuildContext context) {
    final target = widget.progress.clamp(0.0, 1.0);
    final falling = target < _previous;
    _previous = target;
    final duration = widget.reduceMotion
        ? Duration.zero
        : falling
        ? const Duration(milliseconds: 320)
        : const Duration(milliseconds: 50);
    return SizedBox.square(
      dimension: widget.size,
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: 0, end: target),
        duration: duration,
        curve: falling ? Curves.easeOutCubic : Curves.linear,
        builder: (context, value, _) => CustomPaint(
          painter: _SpeedGaugePainter(
            progress: value,
            color: widget.color,
            trackColor: widget.trackColor,
            tickColor: widget.tickColor,
            labelColor: widget.labelColor,
          ),
        ),
      ),
    );
  }
}

class _SpeedGaugePainter extends CustomPainter {
  _SpeedGaugePainter({
    required this.progress,
    required this.color,
    required this.trackColor,
    required this.tickColor,
    required this.labelColor,
  });

  /// 开口朝下的 270° 弧。
  static const double _startAngle = math.pi * 0.75;
  static const double _sweepAngle = math.pi * 1.5;

  final double progress;
  final Color color;
  final Color trackColor;
  final Color tickColor;
  final Color labelColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = math.min(size.width, size.height) / 2 - 10;
    final rect = Rect.fromCircle(center: center, radius: radius);

    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 9
      ..strokeCap = StrokeCap.round
      ..color = trackColor;
    canvas.drawArc(rect, _startAngle, _sweepAngle, false, track);

    final value = progress.clamp(0.0, 1.0);
    if (value > 0) {
      final arc = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 9
        ..strokeCap = StrokeCap.round
        ..color = color;
      canvas.drawArc(rect, _startAngle, _sweepAngle * value, false, arc);
    }

    // 刻度与刻度值画在同一处：刻度值落在指针够不到的地方（针尖 0.6R），
    // 字号跟着半径缩一点，窄屏上不至于叠在一起。刻度在弧上等距，指针的
    // 位置由 [_gaugeAmount] 按同一张表分段换算。
    final tick = Paint()
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round
      ..color = tickColor;
    final segments = _gaugeLabels.length - 1;
    for (var index = 0; index <= segments; index++) {
      final (mbps, text) = _gaugeLabels[index];
      final angle = _startAngle + _sweepAngle * index / segments;
      final direction = Offset(math.cos(angle), math.sin(angle));
      final major = mbps == 0 || mbps == 1000;
      canvas.drawLine(
        center + direction * (radius - (major ? 18 : 13)),
        center + direction * (radius - 7),
        tick,
      );

      final label = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            fontSize: (radius * 0.075).clamp(9.0, 11.0),
            height: 1,
            fontWeight: major ? FontWeight.w600 : FontWeight.w400,
            color: labelColor,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final anchor = center + direction * (radius - 36);
      label.paint(canvas, anchor - Offset(label.width / 2, label.height / 2));
    }

    final angle = _startAngle + _sweepAngle * value;
    final direction = Offset(math.cos(angle), math.sin(angle));
    final needle = Paint()
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round
      ..color = color;
    canvas.drawLine(
      center + direction * (radius * 0.18),
      center + direction * (radius * 0.6),
      needle,
    );
    canvas.drawCircle(center, 3.5, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_SpeedGaugePainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.color != color ||
        oldDelegate.trackColor != trackColor ||
        oldDelegate.tickColor != tickColor ||
        oldDelegate.labelColor != labelColor;
  }
}

/// 表盘下方的读数：大数字一行，方向图标与单位一行。
///
/// 图标跟着单位而不跟数字：46 号的数字旁边再放一个箭头，两者都得缩，还会
/// 把数字从正中推偏；挂到单位那一行，`↓ Mbps` 读起来就是「下行、单位兆」，
/// 数字自己占满一行。
class _SpeedReadout extends StatelessWidget {
  const _SpeedReadout({
    required this.readout,
    required this.valueColor,
    required this.iconColor,
  });

  /// 数字行 52 + 单位行 18。叠放时按它算总高。
  static const double height = 52 + 18;

  final ({String value, String unit, IconData? icon}) readout;
  final Color valueColor;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    final icon = readout.icon;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 52,
          child: Center(
            child: readout.value.isEmpty
                ? const SizedBox.shrink()
                : FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      readout.value,
                      maxLines: 1,
                      style: TextStyle(
                        fontSize: 46,
                        height: 1,
                        fontWeight: FontWeight.w600,
                        color: valueColor,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
          ),
        ),
        // 高度固定：时延阶段没有单位，也不该把下面的内容顶上去。
        SizedBox(
          height: 18,
          child: Center(
            child: readout.unit.isEmpty
                ? const SizedBox.shrink()
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (icon != null) ...[
                        Icon(icon, size: 15, color: iconColor),
                        const SizedBox(width: 4),
                      ],
                      Text(
                        readout.unit,
                        style: ShuYoTextStyles.label(
                          color: colors.textTertiary,
                          size: 12,
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final double? value;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    final text = value == null
        ? '$label -- ms'
        : '$label ${formatSpeedtestNumber(value!)} ms';
    return Text(text, style: ShuYoTextStyles.meta(color: colors.textSecondary));
  }
}

/// 一项延迟读数，可选前置图标。
///
/// 下载与上行的图标就是读数区那一对上下箭头，同一件事用同一个记号；空闲
/// 那项不挂图标 —— 行首的 `PING` 已经说明了它是谁。
class _LatencyValue extends StatelessWidget {
  const _LatencyValue({required this.value, this.icon, this.iconColor});

  final double? value;
  final IconData? icon;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    final text = value == null
        ? '-- ms'
        : '${formatSpeedtestNumber(value!)} ms';
    final icon = this.icon;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 13, color: iconColor ?? colors.textTertiary),
          const SizedBox(width: 3),
        ],
        Text(text, style: ShuYoTextStyles.meta(color: colors.textSecondary)),
      ],
    );
  }
}

class _SpeedStat extends StatelessWidget {
  const _SpeedStat({
    required this.icon,
    required this.label,
    required this.color,
    required this.value,
  });

  final IconData icon;
  final String label;
  final Color color;

  /// 已经算好的读数字符串；null 表示这一格还没有数。
  final String? value;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    final value = this.value;
    return Column(
      children: [
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: ShuYoTextStyles.label(color: colors.textTertiary),
        ),
        const SizedBox(height: 6),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            value ?? '--',
            maxLines: 1,
            style: TextStyle(
              fontSize: 26,
              height: 1.05,
              fontWeight: FontWeight.w600,
              color: value == null ? colors.textMuted : colors.textPrimary,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
        const SizedBox(height: 2),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 4),
            Text('Mbps', style: ShuYoTextStyles.meta(color: colors.textMuted)),
          ],
        ),
      ],
    );
  }
}

class _SpeedIpInfo extends StatelessWidget {
  const _SpeedIpInfo({
    required this.version,
    required this.address,
    required this.isp,
    required this.countryCode,
  });

  final String version;
  final String address;
  final String? isp;
  final String? countryCode;

  @override
  Widget build(BuildContext context) {
    final colors = context.shuyoColors;
    final flag = _flagFor(countryCode);
    final details = [
      ?flag,
      if (isp != null && isp!.trim().isNotEmpty) isp!.trim(),
    ].join(' ');
    final specialAddress = details.isEmpty
        ? _specialAddressLabel(address)
        : null;
    final firstLine = '$version  $address';
    return Column(
      children: [
        LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: constraints.maxWidth),
              child: Text(
                firstLine,
                maxLines: 1,
                softWrap: false,
                textAlign: TextAlign.center,
                textDirection: TextDirection.ltr,
                style: ShuYoTextStyles.label(
                  color: colors.textSecondary,
                  size: 12,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          details.isNotEmpty ? details : specialAddress ?? '--',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: ShuYoTextStyles.meta(color: colors.textTertiary),
        ),
      ],
    );
  }

  static String? _flagFor(String? countryCode) {
    final code = countryCode?.toUpperCase();
    if (code == null || !RegExp(r'^[A-Z]{2}$').hasMatch(code)) return null;
    return String.fromCharCodes(
      code.codeUnits.map((letter) => 0x1F1E6 + letter - 65),
    );
  }

  /// 仅在测速站未提供地理和运营商信息时，标出已知的特殊用途地址。
  static String? _specialAddressLabel(String value) {
    final address = InternetAddress.tryParse(value);
    if (address == null) return null;
    final bytes = address.rawAddress;

    bool inPrefix(List<int> prefix, int length) {
      for (var index = 0; index < length ~/ 8; index++) {
        if (bytes[index] != prefix[index]) return false;
      }
      final remaining = length % 8;
      if (remaining == 0) return true;
      final mask = (0xff << (8 - remaining)) & 0xff;
      return (bytes[length ~/ 8] & mask) == (prefix[length ~/ 8] & mask);
    }

    String label(String rfc, String description) =>
        '🏷️ RFC $rfc · $description';

    if (address.type == InternetAddressType.IPv4) {
      if (inPrefix([0, 0, 0, 0], 32)) return label('1122', '未指定地址');
      if (inPrefix([0, 0, 0, 0], 8)) return label('791', '本网络地址');
      if (inPrefix([10, 0, 0, 0], 8) ||
          inPrefix([172, 16, 0, 0], 12) ||
          inPrefix([192, 168, 0, 0], 16)) {
        return label('1918', '私有网络地址');
      }
      if (inPrefix([100, 64, 0, 0], 10)) {
        return label('6598', '运营商共享地址');
      }
      if (inPrefix([127, 0, 0, 0], 8)) return label('1122', '环回地址');
      if (inPrefix([169, 254, 0, 0], 16)) {
        return label('3927', '链路本地地址');
      }
      if (inPrefix([192, 0, 2, 0], 24) ||
          inPrefix([198, 51, 100, 0], 24) ||
          inPrefix([203, 0, 113, 0], 24)) {
        return label('5737', '文档示例地址');
      }
      if (inPrefix([198, 18, 0, 0], 15)) {
        return label('2544', '性能测试地址');
      }
    } else {
      if (inPrefix(List.filled(16, 0), 128)) {
        return label('4291', '未指定地址');
      }
      if (inPrefix([...List.filled(15, 0), 1], 128)) {
        return label('4291', '环回地址');
      }
      if (inPrefix([0xfc], 7)) return label('4193', '唯一本地地址');
      if (inPrefix([0xfe, 0x80], 10)) {
        return label('4291', '链路本地地址');
      }
      if (inPrefix([0x20, 0x01, 0x0d, 0xb8], 32)) {
        return label('3849', '文档示例地址');
      }
      if (inPrefix([0x3f, 0xff, 0x00], 20)) {
        return label('9637', '文档示例地址');
      }
    }
    return null;
  }
}
