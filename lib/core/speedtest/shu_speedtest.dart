import 'package:flutter/foundation.dart';

/// 一次测速停在哪一阶段。
///
/// [idle] 与 [done] 都不是「正在做」：前者还没开始，后者已经拿到全部结果。
/// 界面靠这个枚举决定读数区显示 Mbps 还是 ms，以及按钮写「开始」还是
/// 「再测一次」。
enum ShuSpeedTestPhase {
  /// 还没开始，或者上一轮已经被取消。
  idle,

  /// 正在量时延与抖动。这一段没有速度可报。
  ping,

  /// 正在量下行。
  download,

  /// 正在量上行。
  upload,

  /// 三个数都拿到了。
  done,
}

/// 测速失败的类型。
///
/// 界面据此决定要不要补一句「为什么」：连不上与超时是同一种用户处境，
/// 而服务端返回 404 是站点本身的问题，不该把责任推给用户的网络。
enum ShuSpeedTestFailure {
  /// TCP / TLS 都没建起来。
  unreachable,

  /// 建起来了，但等不到响应。
  timeout,

  /// 响应不是一个测速后端该有的样子（状态码不对）。
  server,

  /// 用户按了停止。
  cancelled,
}

/// 一次测速失败。
class ShuSpeedTestException implements Exception {
  const ShuSpeedTestException(
    this.message, {
    this.kind = ShuSpeedTestFailure.server,
    this.cause,
  });

  /// 给界面直接显示的一句话。
  final String message;

  final ShuSpeedTestFailure kind;

  /// 原始异常，只用于日志与排查，不显示。
  final Object? cause;

  @override
  String toString() => message;
}

/// 一个 LibreSpeed 站点的入口。
///
/// 上海大学测速站跑的是 LibreSpeed 5.2.5，四个端点固定：
///
/// | 用途 | 路径 |
/// | :--- | :--- |
/// | 下行 | `backend/garbage.php` |
/// | 上行 | `backend/empty.php` |
/// | 时延 / 抖动 | `backend/empty.php` |
/// | 客户端地址 | `backend/getIP.php` |
///
/// 路径做成字段是为了让同一个实现能指向镜像站点或测试用的回环服务器 ——
/// 协议本身与主机名无关。
@immutable
class ShuSpeedTestServer {
  const ShuSpeedTestServer({
    required this.name,
    required this.baseUri,
    this.downloadPath = 'backend/garbage.php',
    this.uploadPath = 'backend/empty.php',
    this.pingPath = 'backend/empty.php',
    this.clientIpPath = 'backend/getIP.php',
  });

  /// 站点名称，用于测速日志和结果。
  final String name;

  final Uri baseUri;

  final String downloadPath;
  final String uploadPath;
  final String pingPath;
  final String clientIpPath;

  /// 上海大学 IPv4 线路。新入口支持从公网访问。
  static final ShuSpeedTestServer shu = ShuSpeedTestServer(
    name: '上海大学测速站',
    baseUri: Uri.parse('https://speedtest.cc.shu.edu.cn/'),
  );

  /// 上海大学 IPv6 线路。与 [shu] 是同一套后端，只是另一条入口。
  static final ShuSpeedTestServer shuIpv6 = ShuSpeedTestServer(
    name: '上海大学测速站 · IPv6',
    baseUri: Uri.parse('https://speedtest6.cc.shu.edu.cn/'),
  );

  Uri get downloadUri => baseUri.resolve(downloadPath);
  Uri get uploadUri => baseUri.resolve(uploadPath);
  Uri get pingUri => baseUri.resolve(pingPath);
  Uri get clientIpUri => baseUri.resolve(clientIpPath);
}

/// 一轮测速的强度。
///
/// 基线是上海大学测速站用的 `speedtest_worker.js`（LibreSpeed 5.2.5）里的
/// `settings`：每次下载 100 MiB、1.5 秒 / 3 秒宽限、1.06 的链路开销补偿、
/// 300 毫秒的流启动间隔，以及 `test_order` 里 IP 之后的 1 秒等待。
///
/// 偏离站点的地方都写在对应字段的注释上，逐条是：并发（8 / 6，站点 6 / 3）、
/// 上行分片（256 KiB）、测量时长（10 秒）、关闭自动缩短、采样间隔（50 毫秒）、
/// 上行正文（1 MiB —— 站点 nginx 的 `client_max_body_size` 只有 1m）。
///
/// 站点还开了 `enable_quirks`：Chrome 会把下行流改成 5，Chrome 移动端会把
/// 上传正文压到 4 MiB。那些是绕 XHR 限制的 UA 特判，原生客户端没有这些
/// 限制。
@immutable
class ShuSpeedTestTuning {
  const ShuSpeedTestTuning({
    this.pingCount = 10,
    this.pingTimeout = const Duration(seconds: 4),
    this.downloadDuration = const Duration(seconds: 10),
    this.uploadDuration = const Duration(seconds: 10),
    this.downloadGrace = const Duration(milliseconds: 1500),
    this.uploadGrace = const Duration(seconds: 3),
    this.downloadStreams = 8,
    this.uploadStreams = 6,
    this.downloadChunkMiB = 100,
    this.uploadBlobMiB = 1,
    this.uploadChunkBytes = 256 * 1024,
    this.sampleInterval = const Duration(milliseconds: 50),
    this.streamStagger = const Duration(milliseconds: 300),
    this.initialDelay = const Duration(seconds: 1),
    this.overheadFactor = 1.06,
    this.autoShorten = false,
    this.startupTimeout = const Duration(seconds: 10),
    this.phaseHold = const Duration(milliseconds: 600),
    this.phaseDrop = const Duration(milliseconds: 400),
  });

  /// 时延采样的次数，对应 `count_ping`。第一条不参与统计。
  final int pingCount;

  /// 单次 ping 的上限。超过就按「站点没响应」处理，不再重试 —— 重试只会
  /// 让用户多等一轮。
  final Duration pingTimeout;

  /// 下载 / 上行的测量时长，对应 `time_dl_max` / `time_ul_max`。
  ///
  /// 这里各取 10 秒。正常收到数据时，宽限结束会重置计时起点，
  /// 因此下行 / 上行实际各跑约 11.5 / 13 秒（另有网络与阶段切换耗时）。
  final Duration downloadDuration;
  final Duration uploadDuration;

  /// 宽限期：开始计时前先让 TCP 窗口与缓冲区进入稳态。
  ///
  /// 下行 1.5 秒、上行 3 秒，与站点一致。
  final Duration downloadGrace;
  final Duration uploadGrace;

  /// 并发流数。
  ///
  /// 多流不是为了提高吞吐，而是为了**填满**一条链路：单条 TCP 连接受窗口与
  /// 握手影响，往往跑不满千兆。站点在 Chrome 上用 6 / 3；这里在下行取 8、
  /// 上行取 6 —— 实测（2026-10-17，校内直连）：下行 6 流 440–516、8 流
  /// 505–506、10 流 463–500，8 流最稳；上行 3 流 166–228、5 流 357–371、
  /// 6 流 377–382、8 流 380–383，6 流之后不再有收益。
  final int downloadStreams;
  final int uploadStreams;

  /// 每次下载请求要服务端生成多少 MiB 随机数据（`garbage.php?ckSize=`）。
  final int downloadChunkMiB;

  /// 上传正文的大小，对应 `xhr_ul_blob_megabytes`。
  ///
  /// worker 的出厂值是 20 MiB，但**站点本身收不下**：`empty.php` 前面那层
  /// nginx 的 `client_max_body_size` 是 1m，超过就回 413 并在收完之前断开。
  /// 以前照搬 20 MiB、又把丢弃的字节计进速度，读数因此虚高（连接已经被服务端
  /// 关掉，客户端还在往里写）。
  ///
  /// 1 MiB 是实测能被 200 接受的最大整块；每条请求只发这一块。
  final int uploadBlobMiB;

  /// 上行每次写进 socket 的分片大小。
  ///
  /// 分片越小，计量越贴近「已经交给系统」而不是「已经塞进应用缓冲」；但每
  /// 块都要一次 `flush` 往返，64 KiB 在 6 条流上把吞吐压到 285–297 Mbps，
  /// 256 KiB 能到 374–382，再放大到 1 MiB 没有额外收益。
  final int uploadChunkBytes;

  /// 采样间隔。
  ///
  /// 站点是 200 毫秒；这里取 50 毫秒（一秒 20 次），数字跳得几乎看不清
  /// 末两位 —— 这正是测速时该有的手感。表盘仍用「累计字节 ÷ 累计时间」
  /// 刷新；阶段结果另取连续 1 秒吞吐率的按时间加权中位数。
  final Duration sampleInterval;

  /// 各条流启动之间的间隔，对应 `xhr_multistreamDelay`。
  ///
  /// 错开是为了不让多条流同时结束、同时重开；站点取 300 毫秒。
  final Duration streamStagger;

  /// 取到客户端地址之后的等待，对应 `test_order` 里的 `_`。
  final Duration initialDelay;

  /// 链路开销补偿系数。
  ///
  /// 应用层字节数不含以太网头与 TCP/IP 头，乘这个系数后与运营商的口径更
  /// 接近。LibreSpeed 默认 1.06。
  final double overheadFactor;

  /// 快链路上提前收尾，对应 `time_auto`。
  ///
  /// 站点的算法是每 200 毫秒按 `5 × speed / 100000` 缩短测量窗口、单次最多
  /// 400 毫秒。400 Mbps 的链路上这意味着每 200 毫秒花掉 400 毫秒的窗口，
  /// 10 秒的测量很快就会收尾 —— 正是「测得太短」的来源。这里关掉它，
  /// 每个阶段真的跑满 [downloadDuration] / [uploadDuration]。
  final bool autoShorten;

  /// 建立 TCP 连接的上限。
  final Duration startupTimeout;

  /// 一个阶段结束后，仪表盘先在最后的过程读数上停一拍。
  ///
  /// 测速跑到最后一帧时数字还在跳，立刻切到下一阶段等于把结果从眼前抹掉。
  /// 停这一下让人看清「这一轮跑到多少」，同时下面那一格填上统计结果。
  final Duration phaseHold;

  /// 停完之后表盘回落、数字归零所用的时间。
  ///
  /// 要留够时间让指针从弧上退回去；太短就是硬切，看不出「收尾」这件事。
  final Duration phaseDrop;
}

/// 与站点 `format()` 相同的取整规则。
///
/// 小于 10 保留两位，小于 100 保留一位，其余取整。下行、上行、时延、
/// 抖动在网页上都是这么显示的。
String formatSpeedtestNumber(double value) {
  if (value < 10) return value.toStringAsFixed(2);
  if (value < 100) return value.toStringAsFixed(1);
  return value.toStringAsFixed(0);
}

/// 测速过程中的一次回调。
@immutable
class ShuSpeedTestProgress {
  const ShuSpeedTestProgress({
    this.phase = ShuSpeedTestPhase.idle,
    this.speedMbps = 0,
    this.progress = 0,
    this.pingMs,
    this.jitterMs,
    this.downloadLatencyMs,
    this.uploadLatencyMs,
    this.downloadMbps,
    this.uploadMbps,
    this.clientIp,
    this.clientIsp,
    this.clientCountryCode,
  });

  final ShuSpeedTestPhase phase;

  /// 仪表盘用的过程读数：当前阶段从宽限结束至今的累计速度。
  /// `ping` 阶段为 0；最终记录的中位数不写入这里。
  final double speedMbps;

  /// 当前阶段的完成度，0..1。
  final double progress;

  /// 已经量到的时延。还没量到时为 null —— 界面据此显示 `--`，而不是 0。
  final double? pingMs;

  final double? jitterMs;

  /// 下载 / 上传跑着的同时量到的时延（负载时延）。
  ///
  /// 空闲时延只能说明链路空着的状态；真正影响使用体验的是「把带宽跑满的
  /// 时候还能不能顺畅交互」。两个阶段各取本阶段内最快的一次往返。
  final double? downloadLatencyMs;
  final double? uploadLatencyMs;

  /// 阶段结束后的下行 / 上行统计结果；测完之前为 null。
  final double? downloadMbps;
  final double? uploadMbps;

  /// 服务端看到的客户端地址。取不到时为 null。
  final String? clientIp;

  /// 服务端识别的运营商和 ISO 3166-1 双字母国家代码。识别不到时为 null。
  final String? clientIsp;
  final String? clientCountryCode;
}

/// 一轮测速的最终结果。
@immutable
class ShuSpeedTestReport {
  const ShuSpeedTestReport({
    required this.server,
    required this.pingMs,
    required this.jitterMs,
    required this.downloadMbps,
    required this.uploadMbps,
    required this.elapsed,
    this.downloadLatencyMs,
    this.uploadLatencyMs,
    this.clientIp,
    this.clientIsp,
    this.clientCountryCode,
  });

  final ShuSpeedTestServer server;

  final double pingMs;
  final double jitterMs;
  final double downloadMbps;
  final double uploadMbps;

  /// 从开始到收尾的实际耗时，含宽限期。
  final Duration elapsed;

  /// 下载 / 上传跑满时的时延；本阶段一次探针都没成功时为 null。
  final double? downloadLatencyMs;
  final double? uploadLatencyMs;

  final String? clientIp;
  final String? clientIsp;
  final String? clientCountryCode;
}

/// 最近一次完成的测速结果。
///
/// 测速页会被路由销毁 —— 返回服务列表再进来，`State` 就换了一颗。结果不该
/// 跟着消失：用户刚看到的那次测速是真实发生过的，重进页面仍然显示同一组
/// 读数，按钮接着是「再测一次」。
///
/// 只保存**跑完**的一份。中途停止或失败的值没有意义，不作为历史。
class ShuSpeedTestHistory {
  ShuSpeedTestHistory._();

  static ShuSpeedTestReport? _last;

  static ShuSpeedTestReport? get last => _last;

  static void record(ShuSpeedTestReport report) => _last = report;

  /// 清空。测试之间互不影响。
  static void reset() => _last = null;
}
