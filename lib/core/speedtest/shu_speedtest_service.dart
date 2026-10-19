import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_sangfor/flutter_sangfor.dart';

import '../connection/shu_http_proxy.dart';
import '../logging/shu_log.dart';
import 'shu_speedtest.dart';

/// 测速的通道。
///
/// 抽成接口只为让页面测试塞替身：真实现每次都要打十秒钟网络，而 widget
/// 测试只关心读数怎么画。
abstract interface class ShuSpeedTestRunner {
  /// 这一轮使用的测速站点。
  ShuSpeedTestServer get server;

  /// 跑完一整轮。中途被 [cancel] 时抛
  /// [ShuSpeedTestFailure.cancelled]。
  Future<ShuSpeedTestReport> run({
    required void Function(ShuSpeedTestProgress progress) onUpdate,
  });

  /// 停掉正在跑的那一轮。没有在跑时是空操作。
  void cancel();
}

/// LibreSpeed 5.x 的测速实现，对齐上海大学测速站。
///
/// ## 走哪条网络
///
/// 按「有没有连上隧道」自动选，两条都不依赖三个数据面开没开：
///
/// | 连接状态 | 走哪 | 怎么走 |
/// | :--- | :--- | :--- |
/// | 已连上隧道 | 应用自己的隧道 | 临时起一条只监听回环、端口随机的 HTTP 代理，拨号交给 [dialer] |
/// | 没连 | 直连 | 进程自己的 [HttpClient]，不设 `findProxy` |
///
/// 隧道那条路复用了设置里那条 HTTP 代理的实现（[ShuHttpProxy]），但**不是
/// 它**：监听地址固定回环、端口由系统分配、只活这一轮，用完就关。所以
/// 「HTTP 代理 / SOCKS5 / 系统 VPN」三个开关全关时，测速照样走应用自己的
/// 通道；三个全开时也不会借用用户配置的那个端口。
///
/// 为什么不直接用 `dart:io` 的 socket：系统 VPN 用
/// `addDisallowedApplication` 把应用自己排除在 TUN 之外（隧道传输不能
/// 自环，见 `ShuVpnService.kt`），进程里的普通 socket 因此走的是底层链路。
/// 要测隧道，就必须经过 [SangforTcpDialer]。
///
/// 直连那一档适用于尚未连接 VPN 的用户；新的测速站入口也支持公网访问。
///
/// ## 与网页端逐项对齐
///
/// 这一段是 `speedtest_worker.js` 的移植，而不是「照同样的协议另写一套」：
///
/// - 顺序：站点 `test_order` 是 `IP_D_U`，取到地址后等 1 秒再测速。
/// - 下行：8 条流、彼此间隔 300 毫秒启动、每次 `ckSize=100`；宽限 1.5 秒
///   后把计数清零重新计时；每 200 毫秒用累计字节数算速度；快链路上按
///   `5 × speed / 100000`（单次不超过 400 毫秒）提前收尾。
/// - 上行：6 条流、每条请求一个 1 MiB 正文（站点写 20 MiB，但它的 nginx 只
///   收到 1 MiB 就回 413）、宽限 3 秒，其余同上。
/// - 读数：`字节 / 秒 × 8 × 1.06 / 1000000`。
/// - 记录值：10 秒内连续 1 秒吞吐窗口的按时间加权中位数；表盘仍显示过程读数。
/// - 收尾：每个阶段跑完先在实时读数上停 [ShuSpeedTestTuning.phaseHold]，再把
///   瞬时值归零、留 [ShuSpeedTestTuning.phaseDrop] 让表盘回落，之后才进
///   下一阶段。
/// - 时延：站点页面本身不跑 `P`；应用要显示时延与抖动，所以直接沿用
///   worker 里 `pingTest` 的原算法（第一个 pong 丢弃、取最小值、加权抖动）。
///
/// 两处实现差异是被平台逼出来的：上行按 256 KiB 逐块 `flush`（浏览器 XHR
/// 自带背压，`dart:io` 的 `addStream` 不给），以及错误处理 —— 站点对网络
/// 错误无限重开，这里对 404/5xx 直接报错，避免用户对着 0.00 等 15 秒。
///
/// 上行计数只算**服务端收下**的字节：一条请求写完后要拿到 200 才作数，
/// 被拒收的那一条会把已计的字节退回。否则链路一慢、服务端提前断开时，
/// 写进本地发送缓冲的字节会被当成已经过网，读数虚高。
class ShuSpeedTestService implements ShuSpeedTestRunner {
  ShuSpeedTestService({
    ShuSpeedTestServer? server,
    this.tuning = const ShuSpeedTestTuning(),
    this.dialer,
  }) : server = server ?? ShuSpeedTestServer.shu;

  @override
  final ShuSpeedTestServer server;

  final ShuSpeedTestTuning tuning;

  /// 隧道内的 TCP 拨号器；为 null 时直连。
  final SangforTcpDialer? dialer;

  static const ShuSpeedTestException _cancelledError = ShuSpeedTestException(
    '测速已停止',
    kind: ShuSpeedTestFailure.cancelled,
  );

  final math.Random _random = math.Random();

  /// 当前阶段正在用的客户端。`cancel()` 要靠它把挂起的 socket 掐掉。
  HttpClient? _client;

  /// 本轮临时代理的 `findProxy` 值。为 null 表示直连。
  String? _findProxy;

  /// 临时代理最近一次拨号失败的原因。
  ///
  /// 代理拨号失败时回的是 502；换掉那句话之前先把它记下来，用户才能看到
  /// 「网关不认这个目标」而不是「下载接口返回 HTTP 502」。
  Object? _dialFailure;

  ({String ip, String? isp, String? countryCode})? _clientInfo;

  bool _running = false;
  bool _cancelled = false;

  @override
  void cancel() {
    if (!_running || _cancelled) return;
    _cancelled = true;
    final client = _client;
    _client = null;
    client?.close(force: true);
  }

  @override
  Future<ShuSpeedTestReport> run({
    required void Function(ShuSpeedTestProgress progress) onUpdate,
  }) async {
    if (_running) {
      throw const ShuSpeedTestException('测速已经开始了');
    }
    _running = true;
    _cancelled = false;
    _findProxy = null;
    _dialFailure = null;
    _clientInfo = null;
    ShuHttpProxy? bridge;
    final watch = Stopwatch()..start();

    try {
      final dialer = this.dialer;
      if (dialer == null) {
        ShuLog.d(ShuLogTag.speedtest, '直连 · 没有可用隧道');
      } else {
        // 只监听回环、端口由系统分配、活到这一轮结束。设置里那条 HTTP 代理
        // 的端口完全不参与，它开没开都一样。
        bridge = ShuHttpProxy(
          dialer: dialer,
          port: 0,
          dialTimeout: tuning.startupTimeout,
          onDialError: (host, port, error) => _dialFailure = error,
        );
        final port = await bridge.start();
        _findProxy = 'PROXY 127.0.0.1:$port';
        ShuLog.d(ShuLogTag.speedtest, '经隧道 · 临时代理 127.0.0.1:$port');
      }

      ShuLog.i(ShuLogTag.speedtest, '开始 · ${server.name}');
      // 站点的 test_order 是 IP_D_U：先取地址，再等 1 秒。地址显示在延迟下方，
      // 取不到也继续测。
      _clientInfo = await _fetchClientInfo();
      final address = _clientInfo?.ip;
      _throwIfCancelled();
      await _pause(tuning.initialDelay);
      _throwIfCancelled();

      onUpdate(
        ShuSpeedTestProgress(
          phase: ShuSpeedTestPhase.ping,
          clientIp: address,
          clientIsp: _clientInfo?.isp,
          clientCountryCode: _clientInfo?.countryCode,
        ),
      );
      final ping = await _measurePing(onUpdate, address);

      // 一个阶段跑完时的收尾：表盘先停在最后的过程读数，再回落。
      //
      // 第一次把统计结果填进下面那一格，但表盘仍停在最后的过程读数；
      // 第二次把表盘速度置 0，指针与数字自己走回去（页面那侧的补间负责
      // 下落动画）。两次之间都断在 `_pause` 上，取消能立刻打断。
      Future<void> settlePhase({
        required ShuSpeedTestPhase phase,
        required double live,
        required double? downloadMbps,
        required double? uploadMbps,
        required double? downloadLatencyMs,
        required double? uploadLatencyMs,
      }) async {
        ShuSpeedTestProgress snapshot(double speed) => ShuSpeedTestProgress(
          phase: phase,
          speedMbps: speed,
          progress: 1,
          pingMs: ping.pingMs,
          jitterMs: ping.jitterMs,
          downloadLatencyMs: downloadLatencyMs,
          uploadLatencyMs: uploadLatencyMs,
          downloadMbps: downloadMbps,
          uploadMbps: uploadMbps,
          clientIp: address,
          clientIsp: _clientInfo?.isp,
          clientCountryCode: _clientInfo?.countryCode,
        );

        onUpdate(snapshot(live));
        await _pause(tuning.phaseHold);
        onUpdate(snapshot(0));
        await _pause(tuning.phaseDrop);
      }

      final download = await _measureDownload(
        onUpdate,
        address,
        ping.pingMs,
        ping.jitterMs,
      );
      await settlePhase(
        phase: ShuSpeedTestPhase.download,
        live: download.liveMbps,
        downloadMbps: download.mbps,
        uploadMbps: null,
        downloadLatencyMs: download.latencyMs,
        uploadLatencyMs: null,
      );
      final upload = await _measureUpload(
        onUpdate,
        address,
        ping.pingMs,
        ping.jitterMs,
        download.mbps,
        download.latencyMs,
      );
      await settlePhase(
        phase: ShuSpeedTestPhase.upload,
        live: upload.liveMbps,
        downloadMbps: download.mbps,
        uploadMbps: upload.mbps,
        downloadLatencyMs: download.latencyMs,
        uploadLatencyMs: upload.latencyMs,
      );
      watch.stop();

      final report = ShuSpeedTestReport(
        server: server,
        pingMs: ping.pingMs,
        jitterMs: ping.jitterMs,
        downloadMbps: download.mbps,
        uploadMbps: upload.mbps,
        downloadLatencyMs: download.latencyMs,
        uploadLatencyMs: upload.latencyMs,
        elapsed: watch.elapsed,
        clientIp: address,
        clientIsp: _clientInfo?.isp,
        clientCountryCode: _clientInfo?.countryCode,
      );
      onUpdate(
        ShuSpeedTestProgress(
          phase: ShuSpeedTestPhase.done,
          speedMbps: 0,
          progress: 1,
          pingMs: report.pingMs,
          jitterMs: report.jitterMs,
          downloadLatencyMs: report.downloadLatencyMs,
          uploadLatencyMs: report.uploadLatencyMs,
          downloadMbps: report.downloadMbps,
          uploadMbps: report.uploadMbps,
          clientIp: address,
          clientIsp: report.clientIsp,
          clientCountryCode: report.clientCountryCode,
        ),
      );
      ShuLog.i(
        ShuLogTag.speedtest,
        '完成 · 时延 ${report.pingMs.toStringAsFixed(1)} ms'
        ' · 抖动 ${report.jitterMs.toStringAsFixed(1)} ms'
        ' · 下载时延 ${_formatLatency(report.downloadLatencyMs)}'
        ' · 上传时延 ${_formatLatency(report.uploadLatencyMs)}'
        ' · 下行 ${report.downloadMbps.toStringAsFixed(2)} Mbps'
        ' · 上行 ${report.uploadMbps.toStringAsFixed(2)} Mbps'
        ' · ${report.elapsed.inSeconds}s',
      );
      return report;
    } on ShuSpeedTestException catch (error) {
      // 在请求飞在半路时按了停止，socket 被掐断后冒出来的通常是 HttpException。
      // 用户看到的原因应该是「我停了」，不是「连不上」。
      if (_cancelled && error.kind != ShuSpeedTestFailure.cancelled) {
        _logFailure(_cancelledError);
        throw _cancelledError;
      }
      // 代理拨号失败时回的是 502；真正的原因在 _dialFailure 里。
      final dialFailure = _dialFailure;
      if (dialFailure is SangforException) {
        final mapped = ShuSpeedTestException(
          '无法经隧道连接测速服务器 · ${dialFailure.message}',
          kind: ShuSpeedTestFailure.unreachable,
          cause: error,
        );
        _logFailure(mapped);
        throw mapped;
      }
      _logFailure(error);
      rethrow;
    } on Object catch (error) {
      if (_cancelled) {
        _logFailure(_cancelledError);
        throw _cancelledError;
      }
      final mapped = _mapError(error);
      _logFailure(mapped);
      throw mapped;
    } finally {
      _running = false;
      _findProxy = null;
      _clientInfo = null;
      final client = _client;
      _client = null;
      client?.close(force: true);
      await bridge?.close();
    }
  }

  // ------------------------------------------------------------------ 时延

  /// `pingTest` 的移植。
  ///
  /// 第一个 pong 只用来校准起点：它把 DNS、TCP 与 TLS 的冷启动都算进去了。
  /// 之后每次取往返时间的最小值，因为排队只会让往返变长；抖动是相邻样本差
  /// 的加权平均，尖峰给 0.7 的权重。
  ///
  /// 站点页面的 `test_order` 是 `IP_D_U`，本身不跑这一段；应用要显示时延
  /// 与抖动，所以沿用同一份 worker 里的算法。浏览器会用 Performance API
  /// 扣掉排队时间，原生没有这个数据源，量的是完整往返。
  Future<({double pingMs, double jitterMs})> _measurePing(
    void Function(ShuSpeedTestProgress progress) onUpdate,
    String? clientIp,
  ) async {
    _throwIfCancelled();
    final client = _openClient();
    var measured = 0;
    var ping = 0.0;
    var jitter = 0.0;
    var previous = 0.0;
    try {
      for (var index = 0; index < tuning.pingCount; index++) {
        _throwIfCancelled();
        final request = await client
            .getUrl(_cacheBusted(server.pingUri))
            .timeout(tuning.pingTimeout);
        request.headers
          ..set(HttpHeaders.acceptEncodingHeader, 'identity')
          ..set(HttpHeaders.cacheControlHeader, 'no-store');
        // 从请求交出去开始计时，和 XHR 的 `send` 到 `onload` 对齐；
        // `getUrl` 只负责拿连接，不该算进往返。
        final watch = Stopwatch()..start();
        final response = await request.close().timeout(tuning.pingTimeout);
        if (response.statusCode != HttpStatus.ok) {
          await response.drain<void>();
          throw ShuSpeedTestException(
            '时延接口返回 HTTP ${response.statusCode}',
            kind: ShuSpeedTestFailure.server,
          );
        }
        await response.drain<void>().timeout(tuning.pingTimeout);
        watch.stop();

        if (index > 0) {
          var instspd = watch.elapsedMicroseconds / 1000;
          // 有的平台会给出 0 毫秒；沿用上一个样本，仍为 0 时按 1 毫秒算。
          if (instspd < 1) instspd = previous;
          if (instspd < 1) instspd = 1;
          final instjitter = (instspd - previous).abs();
          if (measured == 0) {
            ping = instspd;
          } else {
            if (instspd < ping) ping = instspd;
            if (measured == 1) {
              jitter = instjitter;
            } else {
              jitter = instjitter > jitter
                  ? jitter * 0.3 + instjitter * 0.7
                  : jitter * 0.8 + instjitter * 0.2;
            }
          }
          previous = instspd;
          measured++;
        }

        onUpdate(
          ShuSpeedTestProgress(
            phase: ShuSpeedTestPhase.ping,
            progress: (index + 1) / tuning.pingCount,
            pingMs: measured == 0 ? null : ping,
            jitterMs: measured == 0 ? null : jitter,
            clientIp: clientIp,
            clientIsp: _clientInfo?.isp,
            clientCountryCode: _clientInfo?.countryCode,
          ),
        );
      }
    } finally {
      client.close(force: true);
    }
    return (pingMs: ping, jitterMs: jitter);
  }

  // ------------------------------------------------------------------ 下行

  /// `dlTest` 的移植。
  Future<({double mbps, double liveMbps, double? latencyMs})> _measureDownload(
    void Function(ShuSpeedTestProgress progress) onUpdate,
    String? clientIp,
    double pingMs,
    double jitterMs,
  ) async {
    _throwIfCancelled();
    final client = _openClient();
    // 下载跑满的同时打小请求，量「负载时延」。
    final probe = _LoadLatencyProbe(
      uri: server.pingUri,
      timeout: tuning.pingTimeout,
      findProxy: _findProxy,
      bust: _cacheBusted,
    )..start();
    final bytes = List<int>.filled(tuning.downloadStreams, 0);
    final phaseDone = Completer<void>();
    var stopped = false;
    Object? failure;
    var measured = 0.0;

    void stop() {
      if (stopped) return;
      stopped = true;
      if (!phaseDone.isCompleted) phaseDone.complete();
    }

    Future<void> stream(int index) async {
      // 站点的 `setTimeout(1 + xhr_multistreamDelay * i)`：首条立即开始，
      // 其余依次错开 300 毫秒，避免所有流在同一刻结束、同一刻重开。
      if (index > 0) {
        await Future<void>.delayed(tuning.streamStagger * index);
      }
      while (!stopped && !_cancelled) {
        try {
          final request = await client
              .getUrl(
                _cacheBusted(server.downloadUri, {
                  'ckSize': '${tuning.downloadChunkMiB}',
                }),
              )
              .timeout(tuning.startupTimeout);
          request.headers
            ..set(HttpHeaders.acceptEncodingHeader, 'identity')
            ..set(HttpHeaders.cacheControlHeader, 'no-store')
            ..set(HttpHeaders.pragmaHeader, 'no-cache');
          final response = await request.close();
          if (response.statusCode != HttpStatus.ok) {
            await response.drain<void>();
            throw ShuSpeedTestException(
              '下载接口返回 HTTP ${response.statusCode}',
              kind: ShuSpeedTestFailure.server,
            );
          }
          await for (final chunk in response) {
            bytes[index] += chunk.length;
            if (stopped || _cancelled) break;
          }
          // 整块收完立刻重开一条流；XHR 的 `onload` 也是这么做的。
        } on Object catch (error) {
          if (stopped || _cancelled) return;
          if (error is ShuSpeedTestException) {
            // 站点用 `xhr_ignoreErrors: 1` 重开网络流；HTTP 状态码不对是
            // 站点本身的问题，直接报出来。
            failure ??= error;
            stop();
            return;
          }
          // 浏览器的事件循环天然给失败重连限速；这里显式让出 100 毫秒，
          // 免得一个立刻失败的连接把 CPU 打满。
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
    }

    onUpdate(
      ShuSpeedTestProgress(
        phase: ShuSpeedTestPhase.download,
        pingMs: pingMs,
        jitterMs: jitterMs,
        clientIp: clientIp,
        clientIsp: _clientInfo?.isp,
        clientCountryCode: _clientInfo?.countryCode,
      ),
    );
    final streams = <Future<void>>[
      for (var index = 0; index < tuning.downloadStreams; index++)
        stream(index),
    ];
    final watch = Stopwatch()..start();
    // 站点在宽限结束时把 `totLoaded` 清零、`startT` 重置到此刻，然后才
    // 开始算速度。不清零会把宽限期的字节算进测量窗口，读数按
    // `(宽限 + 测量) / 测量` 放大。
    var windowStartUs = 0;
    var graceDone = false;
    var bonusMs = 0.0;
    final throughput = _ThroughputSeries(
      windowUs: math.max(
        1,
        math.min(1000000, tuning.downloadDuration.inMicroseconds ~/ 2),
      ),
      overheadFactor: tuning.overheadFactor,
    );
    // 顶栏那根进度条要的是「整个阶段还剩多少」，所以进度按「宽限 + 测量」
    // 算，从一开始就在走；速度仍只取宽限之后的窗口。
    final totalMs =
        tuning.downloadGrace.inMilliseconds +
        tuning.downloadDuration.inMilliseconds;

    // [speed] 只供表盘显示过程读数；下方的结果格在阶段结束后才填入统计值。
    void report(double speed) {
      final elapsedMs = watch.elapsedMicroseconds / 1000 + bonusMs;
      onUpdate(
        ShuSpeedTestProgress(
          phase: ShuSpeedTestPhase.download,
          speedMbps: speed,
          progress: (elapsedMs / totalMs).clamp(0.0, 1.0),
          pingMs: pingMs,
          jitterMs: jitterMs,
          downloadLatencyMs: probe.minMs,
          clientIp: clientIp,
          clientIsp: _clientInfo?.isp,
          clientCountryCode: _clientInfo?.countryCode,
        ),
      );
    }

    final timer = Timer.periodic(tuning.sampleInterval, (timer) {
      if (_cancelled) stop();
      if (stopped) return;
      final nowUs = watch.elapsedMicroseconds;
      final tMs = (nowUs - windowStartUs) / 1000;

      if (!graceDone) {
        if (tMs > tuning.downloadGrace.inMilliseconds) {
          // 计量窗口始终从宽限结束开始，保证记录统计的是完整的测量阶段。
          windowStartUs = nowUs;
          bonusMs = 0;
          for (var index = 0; index < bytes.length; index++) {
            bytes[index] = 0;
          }
          graceDone = true;
        }
        // 宽限期的这一拍一并结掉：此时 `tMs` 还是相对旧起点的，若继续
        // 往下算，会把「宽限 + 测量」当成已走完而当场停表。
        report(0);
        return;
      }
      if (tMs < tuning.sampleInterval.inMilliseconds) return;

      final totalBytes = _sum(bytes);
      final bytesPerSecond = totalBytes / (tMs / 1000);
      if (tuning.autoShorten) {
        // 每 200 毫秒缩短一点，单次最多 400 毫秒。
        bonusMs += math.min(5.0 * bytesPerSecond / 100000, 400.0);
      }
      // 累计响应字节 / 宽限结束后的实际秒数；1.06 仅估算链路开销。
      measured = bytesPerSecond * 8 * tuning.overheadFactor / 1000000;
      throughput.record(nowUs - windowStartUs, totalBytes);
      report(measured);
      if (tMs + bonusMs > tuning.downloadDuration.inMilliseconds ||
          failure != null) {
        stop();
      }
    });

    await phaseDone.future;
    timer.cancel();
    stop();
    client.close(force: true);
    await Future.wait(streams);
    probe.stop();

    _throwIfCancelled();
    if (failure != null) throw _mapError(failure!);
    if (measured <= 0) {
      throw const ShuSpeedTestException(
        '测速服务器没有返回数据',
        kind: ShuSpeedTestFailure.unreachable,
      );
    }
    return (
      // 结果取连续吞吐窗口的加权中位数；表盘仍用最后一次过程读数。
      mbps: throughput.medianMbps!,
      liveMbps: measured,
      latencyMs: probe.minMs,
    );
  }

  // ------------------------------------------------------------------ 上行

  /// `ulTest` 的移植。
  Future<({double mbps, double liveMbps, double? latencyMs})> _measureUpload(
    void Function(ShuSpeedTestProgress progress) onUpdate,
    String? clientIp,
    double pingMs,
    double jitterMs,
    double downloadMbps,
    double? downloadLatencyMs,
  ) async {
    _throwIfCancelled();
    final client = _openClient();
    final probe = _LoadLatencyProbe(
      uri: server.pingUri,
      timeout: tuning.pingTimeout,
      findProxy: _findProxy,
      bust: _cacheBusted,
    )..start();
    final blob = _uploadBlob(tuning.uploadBlobMiB * 1024 * 1024);
    final bytes = List<int>.filled(tuning.uploadStreams, 0);
    final phaseDone = Completer<void>();
    var stopped = false;
    Object? failure;
    var measured = 0.0;

    void stop() {
      if (stopped) return;
      stopped = true;
      if (!phaseDone.isCompleted) phaseDone.complete();
    }

    Future<void> stream(int index) async {
      // 与下行相同：`xhr_multistreamDelay` 把各条流的启动与重开错开。
      if (index > 0) {
        await Future<void>.delayed(tuning.streamStagger * index);
      }
      while (!stopped && !_cancelled) {
        // 这一条请求已经计过的字节。服务端拒收（非 200）或写到一半断掉时
        // 要退回：那些字节进了内核缓冲、没被对端收下，算进速度就是虚高。
        var requestBytes = 0;
        try {
          final request = await client
              .postUrl(_cacheBusted(server.uploadUri))
              .timeout(tuning.startupTimeout);
          // 与 worker 一致：数据本身不可压缩，中间设备也别试。
          request.headers.set(HttpHeaders.contentEncodingHeader, 'identity');
          // 整块正文一次交给 HTTP 层：XHR 发 Blob 时浏览器自己就带上了
          // `Content-Length`，站点 nginx 对 ≤1 MiB 的正文照收。
          request.contentLength = blob.length;
          // 站点不设 Content-Type，也不设 Content-Length（分块发送）。
          //
          // 逐块 `add` + `flush`，不用 `addStream`：后者不给背压，
          // `add` 只是把字节塞进 socket 的**待写队列**，那个队列可以无界
          // 增长。整块正文会在几十毫秒内压进内存（OOM），而计数也跟着跑到
          // 网络前面（读数虚高）。`flush` 等到这一批字节交给内核，才既把
          // 内存钉在这一块上，又让计数等于真实进度。
          //
          // 一条请求只写**一个** blob，然后正常收尾再开下一条 —— 与 XHR 的
          // `send(req)` / `onload` 一致。以前是在同一条请求里无限循环地写，
          // 永远不结束它：只要服务端提前回错误（例如 nginx 对超长正文回
          // 413），那些写进已关闭连接的字节仍被计进速度，上行读数就虚高。
          var offset = 0;
          while (offset < blob.length && !stopped && !_cancelled) {
            final end = math.min(offset + tuning.uploadChunkBytes, blob.length);
            final chunk = Uint8List.sublistView(blob, offset, end);
            request.add(chunk);
            await request.flush();
            requestBytes += chunk.length;
            bytes[index] += chunk.length;
            offset = end;
          }
          final response = await request.close();
          await response.drain<void>();
          if (stopped || _cancelled) return;
          if (response.statusCode != HttpStatus.ok) {
            throw ShuSpeedTestException(
              '上传接口返回 HTTP ${response.statusCode}',
              kind: ShuSpeedTestFailure.server,
            );
          }
          // 整块发完立刻重开一条流；XHR 的 `upload.onload` 也是这么做的。
        } on Object catch (error) {
          // 测速结束时那一下是人为掐断的，已经写出去的字节照样算数；
          // 真正要退回的是「还在测、却被对端拒收」的那一条请求。
          if (stopped || _cancelled) return;
          bytes[index] = math.max(0, bytes[index] - requestBytes);
          if (error is ShuSpeedTestException) {
            failure ??= error;
            stop();
            return;
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
    }

    onUpdate(
      ShuSpeedTestProgress(
        phase: ShuSpeedTestPhase.upload,
        pingMs: pingMs,
        jitterMs: jitterMs,
        downloadLatencyMs: downloadLatencyMs,
        downloadMbps: downloadMbps,
        clientIp: clientIp,
        clientIsp: _clientInfo?.isp,
        clientCountryCode: _clientInfo?.countryCode,
      ),
    );
    final streams = <Future<void>>[
      for (var index = 0; index < tuning.uploadStreams; index++) stream(index),
    ];
    final watch = Stopwatch()..start();
    // 与下行同理：宽限期的字节不计入测速段。
    var windowStartUs = 0;
    var graceDone = false;
    var bonusMs = 0.0;
    final throughput = _ThroughputSeries(
      windowUs: math.max(
        1,
        math.min(1000000, tuning.uploadDuration.inMicroseconds ~/ 2),
      ),
      overheadFactor: tuning.overheadFactor,
    );
    final totalMs =
        tuning.uploadGrace.inMilliseconds +
        tuning.uploadDuration.inMilliseconds;

    void report(double speed) {
      final elapsedMs = watch.elapsedMicroseconds / 1000 + bonusMs;
      onUpdate(
        ShuSpeedTestProgress(
          phase: ShuSpeedTestPhase.upload,
          speedMbps: speed,
          progress: (elapsedMs / totalMs).clamp(0.0, 1.0),
          pingMs: pingMs,
          jitterMs: jitterMs,
          downloadLatencyMs: downloadLatencyMs,
          uploadLatencyMs: probe.minMs,
          downloadMbps: downloadMbps,
          clientIp: clientIp,
          clientIsp: _clientInfo?.isp,
          clientCountryCode: _clientInfo?.countryCode,
        ),
      );
    }

    final timer = Timer.periodic(tuning.sampleInterval, (timer) {
      if (_cancelled) stop();
      if (stopped) return;
      final nowUs = watch.elapsedMicroseconds;
      final tMs = (nowUs - windowStartUs) / 1000;

      if (!graceDone) {
        if (tMs > tuning.uploadGrace.inMilliseconds) {
          windowStartUs = nowUs;
          bonusMs = 0;
          for (var index = 0; index < bytes.length; index++) {
            bytes[index] = 0;
          }
          graceDone = true;
        }
        // 同下行：这一拍必须结掉，否则会用旧起点的 `tMs` 把自己停表。
        report(0);
        return;
      }
      if (tMs < tuning.sampleInterval.inMilliseconds) return;

      final totalBytes = _sum(bytes);
      final bytesPerSecond = totalBytes / (tMs / 1000);
      if (tuning.autoShorten) {
        bonusMs += math.min(5.0 * bytesPerSecond / 100000, 400.0);
      }
      // 上传计的是 flush 后交给内核的字节，不是服务端逐字节确认的量。
      measured = bytesPerSecond * 8 * tuning.overheadFactor / 1000000;
      throughput.record(nowUs - windowStartUs, totalBytes);
      report(measured);
      if (tMs + bonusMs > tuning.uploadDuration.inMilliseconds ||
          failure != null) {
        stop();
      }
    });

    await phaseDone.future;
    timer.cancel();
    stop();
    client.close(force: true);
    await Future.wait(streams);
    probe.stop();

    _throwIfCancelled();
    if (failure != null) throw _mapError(failure!);
    if (measured <= 0) {
      throw const ShuSpeedTestException(
        '测速服务器没有接收数据',
        kind: ShuSpeedTestFailure.unreachable,
      );
    }
    return (
      mbps: throughput.medianMbps!,
      liveMbps: measured,
      latencyMs: probe.minMs,
    );
  }

  // ------------------------------------------------------------------ 公共

  /// 打开本阶段要用的客户端，并登记为当前客户端。
  ///
  /// 有隧道时 `findProxy` 指向本轮的回环临时代理，否则直连。登记是为了
  /// 让 [cancel] 能把挂起的 socket 直接掐掉。
  HttpClient _openClient() {
    final client = _newClient();
    _client = client;
    return client;
  }

  /// 新建一个会被**这一轮**的代理设置影响的客户端。
  HttpClient _newClient() {
    final client = HttpClient()
      ..connectionTimeout = tuning.startupTimeout
      ..maxConnectionsPerHost =
          math.max(tuning.downloadStreams, tuning.uploadStreams) + 1
      // 测速要量的是链路上的原始字节，不是解压后的字节。
      ..autoUncompress = false
      ..idleTimeout = const Duration(seconds: 10);
    final proxy = _findProxy;
    if (proxy != null) {
      // 只指向这一轮的回环临时代理；它一关，`run` 也结束了。
      client.findProxy = (_) => proxy;
    }
    return client;
  }

  Future<({String ip, String? isp, String? countryCode})?>
  _fetchClientInfo() async {
    // 走 `_client`：取消时 `cancel()` 能直接掐掉这条请求。
    final client = _openClient()
      // 测速流要按原始字节计数；IP 接口返回的 gzip JSON 则必须解压。
      ..autoUncompress = true
      ..connectionTimeout = tuning.pingTimeout
      ..idleTimeout = const Duration(seconds: 2);
    try {
      final request = await client
          .getUrl(
            _cacheBusted(server.clientIpUri, {'isp': 'true', 'distance': 'km'}),
          )
          .timeout(tuning.pingTimeout);
      final response = await request.close().timeout(tuning.pingTimeout);
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        return null;
      }
      final body = await response
          .transform(const Utf8Decoder(allowMalformed: true))
          .join()
          .timeout(tuning.pingTimeout);
      final text = body.trim();
      if (text.startsWith('{')) {
        final decoded = jsonDecode(text);
        if (decoded is Map) {
          final processed = decoded['processedString'];
          if (processed is String) {
            return _parseClientInfo(processed, decoded['rawIspInfo']);
          }
        }
        return null;
      }
      // 旧版 getIP.php 直接回一行纯文本。
      if (text.isEmpty || text.length > 80 || text.contains('<')) return null;
      return _parseClientInfo(text, null);
    } on Object {
      // 地址是附加信息，取不到不影响测速。
      return null;
    } finally {
      client.close(force: true);
    }
  }

  static ({String ip, String? isp, String? countryCode})? _parseClientInfo(
    String processed,
    Object? raw,
  ) {
    final ip = _extractIpAddress(processed);
    if (ip == null) return null;

    String? nonEmpty(Object? value) {
      if (value is! String) return null;
      final text = value.trim();
      return text.isEmpty ? null : text;
    }

    String? isp;
    String? countryCode;
    if (raw is Map) {
      final asn = raw['asn'];
      final name =
          nonEmpty(raw['org']) ??
          (asn is Map ? nonEmpty(asn['name']) : null) ??
          nonEmpty(raw['as_name']);
      isp = name?.replaceFirst(RegExp(r'^AS\d+\s*'), '').trim();
      if (isp?.isEmpty ?? false) isp = null;
      final code = nonEmpty(raw['country']) ?? nonEmpty(raw['country_code']);
      if (code != null && RegExp(r'^[A-Za-z]{2}$').hasMatch(code)) {
        countryCode = code.toUpperCase();
      }
    }

    // 旧站或 ISP 查询失败时 rawIspInfo 可能是空串；从展示字段取运营商。
    final separator = processed.indexOf(' - ');
    if (separator >= 0) {
      var description = processed.substring(separator + 3).trim();
      description = description.replaceFirst(
        RegExp(r' \(<?\d+(?:\.\d+)? (?:km|mi)\)$'),
        '',
      );
      final countrySuffix = RegExp(r', ([A-Za-z]{2})$').firstMatch(description);
      if (countrySuffix != null) {
        countryCode ??= countrySuffix.group(1)?.toUpperCase();
        description = description.substring(0, countrySuffix.start);
      } else if (raw is Map) {
        final countryName = nonEmpty(raw['country_name']);
        if (countryName != null && description.endsWith(', $countryName')) {
          description = description.substring(
            0,
            description.length - countryName.length - 2,
          );
        }
      }
      if (isp == null &&
          description.isNotEmpty &&
          !description.toLowerCase().endsWith(' access')) {
        isp = description;
      }
    }

    return (ip: ip, isp: isp, countryCode: countryCode);
  }

  static String? _extractIpAddress(String value) {
    final text = value.trim();
    if (text.isEmpty) return null;
    // processedString 可能在地址后附带 ISP 或线路说明，只保留 IP。
    final first = text.split(RegExp(r'\s+')).first;
    return InternetAddress.tryParse(first)?.address;
  }

  Uri _cacheBusted(Uri uri, [Map<String, String> extra = const {}]) {
    return uri.replace(
      queryParameters: <String, String>{
        ...uri.queryParameters,
        ...extra,
        'r':
            '${DateTime.now().microsecondsSinceEpoch}'
            '-${_random.nextInt(1 << 32)}',
      },
    );
  }

  /// 各流的字节数之和。
  static int _sum(List<int> values) {
    var total = 0;
    for (final value in values) {
      total += value;
    }
    return total;
  }

  /// 上传用的不可压缩数据。
  ///
  /// 所有流共用这一块；`xorshift` 比 `Random` 快一个数量级，生成的字节也
  /// 不会被任何压缩算法看出花样。
  static Uint8List _uploadBlob(int byteCount) {
    final blob = Uint8List(byteCount);
    var state = 0x9E3779B9;
    for (var index = 0; index < blob.length; index++) {
      state ^= (state << 13) & 0xFFFFFFFF;
      state ^= state >>> 17;
      state ^= (state << 5) & 0xFFFFFFFF;
      state &= 0xFFFFFFFF;
      blob[index] = state & 0xFF;
    }
    return blob;
  }

  /// 分片等待，期间保持对取消的响应。
  Future<void> _pause(Duration duration) async {
    var remaining = duration;
    const step = Duration(milliseconds: 50);
    while (remaining > Duration.zero) {
      _throwIfCancelled();
      final slice = remaining < step ? remaining : step;
      await Future<void>.delayed(slice);
      remaining -= slice;
    }
  }

  void _throwIfCancelled() {
    if (_cancelled) throw _cancelledError;
  }

  void _logFailure(ShuSpeedTestException error) {
    if (error.kind == ShuSpeedTestFailure.cancelled) {
      ShuLog.i(ShuLogTag.speedtest, '已停止');
      return;
    }
    ShuLog.w(ShuLogTag.speedtest, '失败 · ${error.message}');
  }

  ShuSpeedTestException _mapError(Object error) {
    if (error is ShuSpeedTestException) return error;
    if (error is TimeoutException) {
      return ShuSpeedTestException(
        '测速服务器响应超时',
        kind: ShuSpeedTestFailure.timeout,
        cause: error,
      );
    }
    if (error is SocketException) {
      return ShuSpeedTestException(
        '无法连接测速服务器',
        kind: ShuSpeedTestFailure.unreachable,
        cause: error,
      );
    }
    if (error is TlsException || error is HttpException) {
      return ShuSpeedTestException(
        '测速服务器连接中断',
        kind: ShuSpeedTestFailure.unreachable,
        cause: error,
      );
    }
    return ShuSpeedTestException('测速失败：$error', cause: error);
  }

  static String _formatLatency(double? ms) =>
      ms == null ? '--' : '${ms.toStringAsFixed(1)} ms';
}

/// 用连续吞吐窗口的加权中位数作为阶段结果。
///
/// 默认窗口为 1 秒，开头不足 1 秒时使用已走过的时长，沿整段测速滑动。
/// 先从累计字节数求每个窗口的吞吐，
/// 再按采样点实际间隔加权，避免定时器抖动让某段时间被重复算得更多。
/// 中位数保留典型速度，同时不让一次短暂突刺或停顿主导最终结果。
class _ThroughputSeries {
  _ThroughputSeries({required this.windowUs, required this.overheadFactor});

  final int windowUs;
  final double overheadFactor;
  final List<({int elapsedUs, int bytes})> _points = [(elapsedUs: 0, bytes: 0)];
  final List<({double mbps, int weightUs})> _rates = [];
  int _anchor = 0;

  void record(int elapsedUs, int bytes) {
    final previous = _points.last;
    if (elapsedUs <= previous.elapsedUs) return;
    _points.add((elapsedUs: elapsedUs, bytes: bytes));
    final activeWindowUs = math.min(elapsedUs, windowUs);
    final startUs = elapsedUs - activeWindowUs;
    while (_anchor + 1 < _points.length &&
        _points[_anchor + 1].elapsedUs <= startUs) {
      _anchor++;
    }
    final left = _points[_anchor];
    final right = _points[_anchor + 1];
    final fraction =
        (startUs - left.elapsedUs) / (right.elapsedUs - left.elapsedUs);
    final bytesAtStart = left.bytes + (right.bytes - left.bytes) * fraction;
    final windowBytes = math.max(0, bytes - bytesAtStart);
    final mbps = windowBytes * 8 * overheadFactor / activeWindowUs;
    _rates.add((mbps: mbps, weightUs: elapsedUs - previous.elapsedUs));
  }

  double? get medianMbps {
    if (_rates.isEmpty) return null;
    final sorted = [..._rates]..sort((a, b) => a.mbps.compareTo(b.mbps));
    final totalWeight = sorted.fold<int>(0, (sum, rate) => sum + rate.weightUs);
    var weight = 0;
    for (final rate in sorted) {
      weight += rate.weightUs;
      if (weight * 2 >= totalWeight) return rate.mbps;
    }
    return sorted.last.mbps;
  }
}

/// 负载下的时延探测。
///
/// 下载 / 上传跑满的同时，每 500 毫秒向 ping 接口打一个最小请求，取这一
/// 阶段里最快的一次往返 —— 就是 Ookla 那三个延迟里的「下载延迟」「上传
/// 延迟」。空闲时延只能说明链路空着时的状态；把带宽跑满时还能不能顺畅
/// 交互，看的是这个数。
///
/// 用独立的 [HttpClient]：测速流的连接已经把主客户端的并发槽占满，挤在
/// 一起会让探针排在队尾，量到的是排队时间而不是链路时延。
class _LoadLatencyProbe {
  _LoadLatencyProbe({
    required this.uri,
    required this.timeout,
    required this.findProxy,
    required this.bust,
  });

  /// 500 毫秒一次：太密会和测速流抢连接，太疏则采不到足够样本。
  static const Duration _interval = Duration(milliseconds: 500);

  final Uri uri;
  final Duration timeout;

  /// 与测速流走同一条通道（有隧道时指向本轮的回环代理）。
  final String? findProxy;

  /// 加时间戳，避免中间缓存把探针请求直接命中掉。
  final Uri Function(Uri uri) bust;

  final HttpClient _client = HttpClient();

  Timer? _timer;
  bool _busy = false;
  bool _stopped = false;
  double? _minMs;

  /// 本阶段测到的最小时延；一次都没成功时为 null。
  double? get minMs => _minMs;

  void start() {
    _client
      ..connectionTimeout = timeout
      ..maxConnectionsPerHost = 1
      ..autoUncompress = false
      ..idleTimeout = const Duration(seconds: 5);
    final proxy = findProxy;
    if (proxy != null) _client.findProxy = (_) => proxy;
    _timer = Timer.periodic(_interval, (_) => _probe());
    _probe();
  }

  Future<void> _probe() async {
    if (_busy || _stopped) return;
    _busy = true;
    final watch = Stopwatch()..start();
    try {
      final request = await _client.getUrl(bust(uri)).timeout(timeout);
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      final response = await request.close().timeout(timeout);
      await response.drain<void>().timeout(timeout);
      watch.stop();
      if (response.statusCode != HttpStatus.ok) return;
      final ms = watch.elapsedMicroseconds / 1000;
      final min = _minMs;
      if (min == null || ms < min) _minMs = ms;
    } on Object {
      // 探针只是附加读数，失败就等下一跳。
    } finally {
      _busy = false;
    }
  }

  void stop() {
    _stopped = true;
    _timer?.cancel();
    _client.close(force: true);
  }
}
