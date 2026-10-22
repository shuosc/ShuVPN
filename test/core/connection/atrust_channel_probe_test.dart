import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_sangfor_atrust/flutter_sangfor_atrust.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuvpn/core/connection/atrust_channel_probe.dart';

/// 记录并发度与顺序的假通道。
///
/// 真实现（[ATrustSecureSocketChannel]）是 `add` + `await flush()`，
/// `flush()` 期间 sink 处于 bound 状态；这里用一个「同一时刻只允许一笔
/// 写入」的断言把同一个约束表达出来。
class _FakeChannel implements ATrustTunnelChannel {
  final StreamController<List<int>> _incoming = StreamController<List<int>>();
  final List<String> events = <String>[];
  int live = 0;
  int maxLive = 0;
  bool closed = false;

  @override
  Stream<List<int>> get incoming => _incoming.stream;

  @override
  Future<void> send(Uint8List bytes) async {
    live++;
    maxLive = math.max(maxLive, live);
    try {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      events.add('send ${bytes.first}');
    } finally {
      live--;
    }
  }

  @override
  Future<void> close() async {
    closed = true;
    events.add('close');
  }
}

Uint8List _byte(int value) => Uint8List.fromList(<int>[value]);

void main() {
  test('并发写入被排成一条队，顺序不变', () async {
    final inner = _FakeChannel();
    final probe = ShuATrustChannelProbe(inner, id: 1, host: 'h', port: 443);

    await Future.wait(<Future<void>>[
      probe.send(_byte(1)),
      probe.send(_byte(2)),
      probe.send(_byte(3)),
    ]);

    expect(inner.maxLive, 1, reason: '同一时刻只能有一笔写入在飞');
    expect(inner.events, <String>['send 1', 'send 2', 'send 3']);
  });

  test('close 排在未完成的写入之后，且只关一次', () async {
    final inner = _FakeChannel();
    final probe = ShuATrustChannelProbe(inner, id: 1, host: 'h', port: 443);

    final sending = probe.send(_byte(1));
    final closing = probe.close();
    final again = probe.close();
    await Future.wait(<Future<void>>[sending, closing, again]);

    expect(inner.events, <String>['send 1', 'close']);
    expect(inner.closed, isTrue);
  });

  test('关闭后再写入立即失败', () async {
    final inner = _FakeChannel();
    final probe = ShuATrustChannelProbe(inner, id: 1, host: 'h', port: 443);

    await probe.close();

    await expectLater(probe.send(_byte(1)), throwsA(isA<StateError>()));
    expect(inner.events, <String>['close']);
  });
}
