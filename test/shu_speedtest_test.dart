// 测速核心的离线单测。
//
// 全部打在回环上：一个真的 `HttpServer` 扮演 LibreSpeed 后端，客户端是生产
// 那一份 `ShuSpeedTestService`。不 mock `HttpClient`，因为这里要验证的正是
// 「分块下载 / 分块上传 / 时延采样」这几条真实的字节行为。

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_sangfor/flutter_sangfor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuvpn/core/speedtest/shu_speedtest.dart';
import 'package:shuvpn/core/speedtest/shu_speedtest_service.dart';

/// 把站点的 15 秒压到几百毫秒，其余口径与出厂值一致。
const ShuSpeedTestTuning _fast = ShuSpeedTestTuning(
  pingCount: 4,
  pingTimeout: Duration(seconds: 2),
  downloadDuration: Duration(milliseconds: 400),
  uploadDuration: Duration(milliseconds: 400),
  downloadGrace: Duration(milliseconds: 100),
  uploadGrace: Duration(milliseconds: 100),
  downloadStreams: 2,
  uploadStreams: 2,
  downloadChunkMiB: 1,
  uploadBlobMiB: 1,
  uploadChunkBytes: 32 * 1024,
  sampleInterval: Duration(milliseconds: 50),
  streamStagger: Duration.zero,
  initialDelay: Duration.zero,
  autoShorten: false,
  startupTimeout: Duration(seconds: 2),
  // 收尾停顿只为了手感，测试不需要。
  phaseHold: Duration.zero,
  phaseDrop: Duration.zero,
);

void main() {
  test('出厂参数与站点 speedtest_worker.js 一致', () {
    const tuning = ShuSpeedTestTuning();
    expect(tuning.pingCount, 10);
    // 站点是 6 / 3；实测 8 / 6 才能把链路跑满（见字段注释）。
    expect(tuning.downloadStreams, 8);
    expect(tuning.uploadStreams, 6);
    expect(tuning.downloadDuration, const Duration(seconds: 10));
    expect(tuning.uploadDuration, const Duration(seconds: 10));
    expect(tuning.downloadGrace, const Duration(milliseconds: 1500));
    expect(tuning.uploadGrace, const Duration(seconds: 3));
    expect(tuning.downloadChunkMiB, 100);
    // 站点 worker 写的是 20 MiB，但它自己的 nginx 只收到 1 MiB 就回 413。
    // 照搬 20 MiB 会让每条上传请求都被拒，计数却照跑 —— 读数虚高。
    expect(tuning.uploadBlobMiB, 1);
    // 站点是 200 ms；这里一秒 20 次，数字跳得看不清末两位。
    expect(tuning.sampleInterval, const Duration(milliseconds: 50));
    expect(tuning.streamStagger, const Duration(milliseconds: 300));
    expect(tuning.initialDelay, const Duration(seconds: 1));
    expect(tuning.overheadFactor, 1.06);
    // 站点的 time_auto 会在快链路上缩短测速时间，这里关掉，跑满窗口。
    expect(tuning.autoShorten, isFalse);
  });

  test('读数格式与站点 format() 一致', () {
    expect(formatSpeedtestNumber(9.999), '10.00');
    expect(formatSpeedtestNumber(31.2), '31.2');
    expect(formatSpeedtestNumber(88.5), '88.5');
    expect(formatSpeedtestNumber(12), '12.0');
    expect(formatSpeedtestNumber(1234.5), '1235');
  });

  late HttpServer server;
  late ShuSpeedTestServer target;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(_serve);
    target = ShuSpeedTestServer(
      name: 'loopback',
      baseUri: Uri.parse('http://127.0.0.1:${server.port}/'),
    );
  });

  tearDown(() async {
    await server.close(force: true);
  });

  test('跑完一轮：时延、下行、上行都有读数', () async {
    final service = ShuSpeedTestService(server: target, tuning: _fast);
    final phases = <ShuSpeedTestPhase>[];
    final updates = <ShuSpeedTestProgress>[];
    final report = await service
        .run(
          onUpdate: (progress) {
            phases.add(progress.phase);
            updates.add(progress);
          },
        )
        .timeout(const Duration(seconds: 30));

    expect(report.pingMs, greaterThanOrEqualTo(0));
    expect(report.downloadMbps, greaterThan(0));
    expect(report.uploadMbps, greaterThan(0));
    // getIP.php 的 gzip 响应要解压，并分别保留 IP、运营商和国家代码。
    expect(report.clientIp, '127.0.0.1');
    expect(report.clientIsp, 'China Telecom (Group)');
    expect(report.clientCountryCode, 'CN');
    expect(updates.last.clientIsp, 'China Telecom (Group)');
    expect(updates.last.clientCountryCode, 'CN');
    expect(
      phases,
      containsAllInOrder(<ShuSpeedTestPhase>[
        ShuSpeedTestPhase.ping,
        ShuSpeedTestPhase.download,
        ShuSpeedTestPhase.upload,
        ShuSpeedTestPhase.done,
      ]),
    );
    expect(
      phases.where((phase) => phase == ShuSpeedTestPhase.done),
      hasLength(1),
    );

    // 收尾时仪表盘沿用最后的过程读数；统计结果只填入下方结果格。
    final downloadSettle = updates.firstWhere(
      (update) =>
          update.phase == ShuSpeedTestPhase.download &&
          update.speedMbps == 0 &&
          update.downloadMbps != null,
    );
    expect(downloadSettle.downloadMbps, closeTo(report.downloadMbps, 1e-9));
    final downloadLastSample = updates.lastWhere(
      (update) =>
          update.phase == ShuSpeedTestPhase.download &&
          update.downloadMbps == null,
    );
    final downloadHold = updates.firstWhere(
      (update) =>
          update.phase == ShuSpeedTestPhase.download &&
          update.downloadMbps != null &&
          update.speedMbps > 0,
    );
    expect(downloadHold.speedMbps, downloadLastSample.speedMbps);
    final uploadSettle = updates.firstWhere(
      (update) =>
          update.phase == ShuSpeedTestPhase.upload &&
          update.speedMbps == 0 &&
          update.uploadMbps != null,
    );
    expect(uploadSettle.uploadMbps, closeTo(report.uploadMbps, 1e-9));
    final uploadLastSample = updates.lastWhere(
      (update) =>
          update.phase == ShuSpeedTestPhase.upload && update.uploadMbps == null,
    );
    final uploadHold = updates.firstWhere(
      (update) =>
          update.phase == ShuSpeedTestPhase.upload &&
          update.uploadMbps != null &&
          update.speedMbps > 0,
    );
    expect(uploadHold.speedMbps, uploadLastSample.speedMbps);
    expect(updates.last.speedMbps, 0);
  });

  test('给了隧道拨号器时，请求经临时回环代理走拨号器', () async {
    final dialed = <String>[];
    final service = ShuSpeedTestService(
      server: target,
      tuning: _fast,
      dialer: (host, port) async {
        dialed.add('$host:$port');
        return SocketTcpStream(await Socket.connect(host, port));
      },
    );

    final report = await service
        .run(onUpdate: (_) {})
        .timeout(const Duration(seconds: 30));

    // 每一跳（ping / 下载 / 上传 / getIP）都应该经过拨号器，而不是直连。
    expect(dialed, isNotEmpty);
    expect(dialed, everyElement('127.0.0.1:${server.port}'));
    expect(report.downloadMbps, greaterThan(0));
    expect(report.uploadMbps, greaterThan(0));
  });

  test('经隧道时上行读数跟隧道速率走，而不是回环速度', () async {
    const bytesPerSecond = 2 * 1000 * 1000; // 16 Mbps
    final service = ShuSpeedTestService(
      server: target,
      dialer: (host, port) async => _ThrottledStream(
        SocketTcpStream(await Socket.connect(host, port)),
        bytesPerSecond: bytesPerSecond,
      ),
      // 窗口要留够：CI 上光是把第一批字节推过「客户端 → 代理 → 隧道」就要
      // 几百毫秒，窗口太短会让整段测量落在计时开始之前（读数是 0）。
      tuning: const ShuSpeedTestTuning(
        pingCount: 2,
        pingTimeout: Duration(seconds: 2),
        downloadStreams: 1,
        uploadStreams: 1,
        downloadGrace: Duration(milliseconds: 100),
        uploadGrace: Duration(milliseconds: 300),
        downloadDuration: Duration(milliseconds: 200),
        uploadDuration: Duration(milliseconds: 1500),
        uploadBlobMiB: 1,
        uploadChunkBytes: 32 * 1024,
        sampleInterval: Duration(milliseconds: 50),
        autoShorten: false,
        startupTimeout: Duration(seconds: 5),
      ),
    );

    final report = await service
        .run(onUpdate: (_) {})
        .timeout(const Duration(seconds: 60));

    // 16 Mbps × 1.06 ≈ 17 Mbps。代理的排队上限（256 KiB）会让读数偏高一点，
    // 但绝不该是回环的几百 Mbps —— 那正是「速度特别偏大」的成因。
    expect(report.uploadMbps, greaterThan(5));
    expect(report.uploadMbps, lessThan(40), reason: '上行计数跑到隧道前面去了');
  });

  test('服务端拒收正文时，丢弃的字节不会算成上传速度', () async {
    // 复刻站点的 nginx：`client_max_body_size 1m`，超过就 413 并断开。
    // 以前的实现会在同一条请求里无限写，被拒收的字节照样计数 —— 读数虚高。
    final strict = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    strict.listen((request) async {
      if (request.uri.path != '/backend/empty.php') {
        await _serve(request);
        return;
      }
      var seen = 0;
      try {
        await for (final chunk in request) {
          seen += chunk.length;
          if (seen > 1024 * 1024) break;
        }
      } on Object {
        // 客户端被掐断时读会抛。
      }
      try {
        request.response.statusCode = HttpStatus.requestEntityTooLarge;
        await request.response.close();
      } on Object {
        // 同上。
      }
    });
    addTearDown(() => strict.close(force: true));

    final service = ShuSpeedTestService(
      server: ShuSpeedTestServer(
        name: 'strict',
        baseUri: Uri.parse('http://127.0.0.1:${strict.port}/'),
      ),
      tuning: const ShuSpeedTestTuning(
        pingCount: 2,
        pingTimeout: Duration(seconds: 2),
        downloadStreams: 1,
        uploadStreams: 1,
        downloadGrace: Duration(milliseconds: 100),
        uploadGrace: Duration(milliseconds: 100),
        downloadDuration: Duration(milliseconds: 300),
        uploadDuration: Duration(milliseconds: 400),
        // 比服务端上限大一倍：每条请求都会被 413 掉。
        uploadBlobMiB: 2,
        uploadChunkBytes: 32 * 1024,
        sampleInterval: Duration(milliseconds: 50),
        streamStagger: Duration.zero,
        autoShorten: false,
        startupTimeout: Duration(seconds: 2),
      ),
    );

    // 结果只能是「失败」，不能是一串看着很快的读数。
    await expectLater(
      service.run(onUpdate: (_) {}),
      throwsA(isA<ShuSpeedTestException>()),
    );
  });

  test('宽限期的字节不算进测速窗口，读数不会虚高', () async {
    // 一个速率固定的后端：每 20 ms 吐 64 KiB，约 25 Mbps。
    final slow = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    slow.listen((request) async {
      request.response.headers.contentType = ContentType.binary;
      if (request.uri.path == '/backend/garbage.php') {
        final chunk = Uint8List(64 * 1024);
        try {
          while (true) {
            request.response.add(chunk);
            await request.response.flush();
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
        } on Object {
          // 客户端收够了就断，正常。
        }
      }
      try {
        await request.response.close();
      } on Object {
        // 同上。
      }
    });
    addTearDown(() => slow.close(force: true));

    final service = ShuSpeedTestService(
      server: ShuSpeedTestServer(
        name: 'slow',
        baseUri: Uri.parse('http://127.0.0.1:${slow.port}/'),
      ),
      tuning: const ShuSpeedTestTuning(
        pingCount: 2,
        pingTimeout: Duration(seconds: 2),
        downloadStreams: 1,
        uploadStreams: 1,
        downloadGrace: Duration(milliseconds: 300),
        uploadGrace: Duration(milliseconds: 300),
        downloadDuration: Duration(milliseconds: 300),
        uploadDuration: Duration(milliseconds: 300),
        uploadChunkBytes: 32 * 1024,
        sampleInterval: Duration(milliseconds: 50),
        autoShorten: false,
        startupTimeout: Duration(seconds: 2),
      ),
    );

    final report = await service
        .run(onUpdate: (_) {})
        .timeout(const Duration(seconds: 30));

    // 宽限期 300 ms 与测量段 300 ms 等长。旧实现把两段的字节都算进 300 ms，
    // 读数会翻倍到 50 Mbps 以上；正确的口径应落在 25 Mbps 附近。
    expect(report.downloadMbps, greaterThan(10));
    expect(report.downloadMbps, lessThan(40), reason: '宽限期的字节被算进了测速段');
  });

  test('上行计数跟随服务端读取速度，不把本地待写队列当网络速度', () async {
    // 服务端每读一块歇 100 ms，相当于几 Mbps 的接收速度。旧实现用
    // `addStream`（不给背压），8 MiB 会在几十毫秒内全压进 socket 的待写
    // 队列：既占内存，又让读数跑成回环速度。
    final slow = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    slow.listen((request) async {
      try {
        if (request.uri.path == '/backend/empty.php') {
          await for (final _ in request) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
        } else if (request.uri.path == '/backend/garbage.php') {
          request.response.add(Uint8List(64 * 1024));
        } else if (request.uri.path == '/backend/getIP.php') {
          request.response.write('{"processedString":"127.0.0.1"}');
        }
        await request.response.close();
      } on Object {
        // 客户端被强制断开是常态。
      }
    });
    addTearDown(() => slow.close(force: true));

    final service = ShuSpeedTestService(
      server: ShuSpeedTestServer(
        name: 'slow-up',
        baseUri: Uri.parse('http://127.0.0.1:${slow.port}/'),
      ),
      tuning: const ShuSpeedTestTuning(
        pingCount: 1,
        pingTimeout: Duration(seconds: 2),
        downloadStreams: 1,
        uploadStreams: 1,
        downloadGrace: Duration(milliseconds: 50),
        uploadGrace: Duration(milliseconds: 100),
        downloadDuration: Duration(milliseconds: 100),
        uploadDuration: Duration(milliseconds: 800),
        uploadBlobMiB: 8,
        uploadChunkBytes: 64 * 1024,
        sampleInterval: Duration(milliseconds: 50),
        autoShorten: false,
        startupTimeout: Duration(seconds: 2),
      ),
    );

    final report = await service
        .run(onUpdate: (_) {})
        .timeout(const Duration(seconds: 30));

    // 服务端每 100 ms 收一块。读数里必然含「已经写进内核、对端还没读」的那
    // 一段，而这段的大小取决于平台默认的 socket 缓冲（Linux 上比 Windows
    // 大得多，实测同一份代码 266 与 120 的差别）。所以门槛只卡一个数量级：
    // 无背压那次是几千 Mbps，正常实现不会过 800。
    expect(report.uploadMbps, greaterThan(0));
    expect(report.uploadMbps, lessThan(800), reason: '上行计数跑到服务端真实接收速度前面去了');
  });

  test('取消之后抛 cancelled，不会继续跑完', () async {
    final service = ShuSpeedTestService(server: target, tuning: _fast);
    final future = service.run(
      onUpdate: (progress) {
        if (progress.phase == ShuSpeedTestPhase.download) service.cancel();
      },
    );

    await expectLater(
      future.timeout(const Duration(seconds: 30)),
      throwsA(
        isA<ShuSpeedTestException>().having(
          (error) => error.kind,
          'kind',
          ShuSpeedTestFailure.cancelled,
        ),
      ),
    );
  });

  test('在时延阶段取消也报 cancelled，不会被当成断网', () async {
    final service = ShuSpeedTestService(server: target, tuning: _fast);
    final future = service.run(
      onUpdate: (progress) {
        if (progress.phase == ShuSpeedTestPhase.ping) service.cancel();
      },
    );

    await expectLater(
      future.timeout(const Duration(seconds: 30)),
      throwsA(
        isA<ShuSpeedTestException>().having(
          (error) => error.kind,
          'kind',
          ShuSpeedTestFailure.cancelled,
        ),
      ),
    );
  });

  test('后端路径不对时报服务端失败', () async {
    final missing = ShuSpeedTestServer(
      name: 'missing',
      baseUri: target.baseUri.resolve('missing/'),
    );
    final service = ShuSpeedTestService(server: missing, tuning: _fast);

    await expectLater(
      service.run(onUpdate: (_) {}).timeout(const Duration(seconds: 30)),
      throwsA(
        isA<ShuSpeedTestException>().having(
          (error) => error.kind,
          'kind',
          ShuSpeedTestFailure.server,
        ),
      ),
    );
  });

  test('端口没人监听时报连不上', () async {
    // 先占一个端口再放掉，拿到一个刚刚关闭、大概率不会立刻被复用的号。
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();

    final dead = ShuSpeedTestServer(
      name: 'dead',
      baseUri: Uri.parse('http://127.0.0.1:$port/'),
    );
    final service = ShuSpeedTestService(server: dead, tuning: _fast);

    await expectLater(
      service.run(onUpdate: (_) {}).timeout(const Duration(seconds: 30)),
      throwsA(
        isA<ShuSpeedTestException>().having(
          (error) => error.kind,
          'kind',
          anyOf(ShuSpeedTestFailure.unreachable, ShuSpeedTestFailure.timeout),
        ),
      ),
    );
  });
}

/// 一条限速的隧道流：每次 `send` 之后按速率等一会儿，让上行真的慢下来。
class _ThrottledStream extends SangforTcpStream {
  _ThrottledStream(this._inner, {required this.bytesPerSecond});

  final SocketTcpStream _inner;
  final int bytesPerSecond;

  @override
  Stream<Uint8List> get incoming => _inner.incoming;

  @override
  bool get isClosed => _inner.isClosed;

  @override
  Future<void> send(Uint8List data) async {
    await _inner.send(data);
    await Future<void>.delayed(
      Duration(microseconds: (data.length * 1000000 / bytesPerSecond).round()),
    );
  }

  @override
  Future<void> closeWrite() => _inner.closeWrite();

  @override
  Future<void> close() => _inner.close();
}

/// 一个最小的 LibreSpeed 后端。
///
/// 下载每次回 512 KiB（分八次写、每次隔 1 ms），把回环的吞吐压到几十 MB/s，
/// 免得测试变成内存压测；上传与 ping 共用一个把请求体读干净的端点。
Future<void> _serve(HttpRequest request) async {
  try {
    await _handle(request);
  } on Object {
    // 上下行阶段结束时客户端会被强制掐断，服务端读到的是半截请求。
  }
}

Future<void> _handle(HttpRequest request) async {
  switch (request.uri.path) {
    case '/backend/garbage.php':
      final response = request.response
        ..headers.contentType = ContentType.binary
        ..headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      final chunk = Uint8List(64 * 1024);
      for (var index = 0; index < 8; index++) {
        response.add(chunk);
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      await response.close();
      return;
    case '/backend/empty.php':
      await request.drain<void>();
      await request.response.close();
      return;
    case '/backend/getIP.php':
      request.response
        ..headers.contentType = ContentType.json
        ..headers.set(HttpHeaders.contentEncodingHeader, 'gzip')
        ..add(
          gzip.encode(
            '{"processedString":"127.0.0.1 - China Telecom (Group), CN","rawIspInfo":{"org":"AS4134 China Telecom (Group)","country":"CN"}}'
                .codeUnits,
          ),
        );
      await request.response.close();
      return;
    default:
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
  }
}
