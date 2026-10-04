import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'shu_announcement.dart';
import 'shu_announcement_parser.dart';

/// 请求种类。跨 isolate 传的是数字，两侧取值必须一致。
const int _listRequest = 0;
const int _detailRequest = 1;

/// 后台那条 isolate 没了时的说法。它会自愈：下一次请求重新起一条。
const String _parserGone = '公告解析服务已停止';

/// 在后台 isolate 上解析公告的 HTML。
///
/// ## 为什么不在界面 isolate 上解析
///
/// 解析是纯 CPU 活。站点把 Word 转出来的嵌套 `div` 原样贴进模板，一篇正文能到
/// 几百 KB，`html_parser.parse` 要按字符建一整棵树 —— 放在界面 isolate 上跑，
/// 一篇就能吃掉一帧。通知页打开时会同时预取十条（见 `NotificationsPage`），几条
/// 排进同一个帧就是连着掉帧，滑起来正是「卡」的那一下。解码也一并搬过来：几百
/// KB 的 UTF-8 解出来是一整个字符串，那同样是一笔算在界面上的时间。
///
/// ## 为什么是常驻的一条而不是每次开一条
///
/// `Isolate.spawn` 自己也要花时间，而那点时间花在**界面 isolate** 上：并发越
/// 高，挤进同一帧的 `spawn` 越多 —— 那样「并发数」又变成了会不会掉帧的开关。
/// 这里改成一条常驻的解析 isolate，请求排队进去、结果按 id 出来：并发只决定
/// 队列有多长，界面 isolate 的占用与它无关。
///
/// ## 请求与应答
///
/// 请求是 `[id, 种类, …参数]`，应答是 `[id, 结果, 错误文本]`。两条 isolate 属于
/// 同一个 isolate group，所以解析结果（一棵普通的 Dart 对象树）可以直接送回来，
/// 不必先序列化成 JSON 再在这边拼一遍。
///
/// 这条 isolate 活到进程结束；[close] 是给退出路径与测试用的。
class ShuAnnouncementParserHost {
  Isolate? _isolate;
  ReceivePort? _events;
  ReceivePort? _exit;

  /// 已经起好的那条 isolate 的投递端口。null = 还没起，或者已经收掉了。
  Future<SendPort>? _channel;

  /// 等回应的请求，以 id 为键。
  final Map<int, Completer<Object?>> _pending = <int, Completer<Object?>>{};

  int _nextId = 0;

  /// 每起一条 isolate 递增一次。收尾时拿它判断「手上这几个字段还是不是那一条
  /// 的」—— 旧的那条死掉时新的可能已经起来了，不能顺手把新的端口抹掉。
  int _generation = 0;

  bool _closed = false;

  /// 解析一页列表。[body] 是响应体的**原始字节**，解码在这一侧做。
  Future<ShuAnnouncementPage> parseList(
    Uint8List body, {
    required Uri baseUri,
  }) async {
    final result = await _send(_listRequest, <Object?>[body, baseUri]);
    return result! as ShuAnnouncementPage;
  }

  /// 解析一篇正文。[fallbackTitle] / [fallbackDateText] 见 `parseAnnouncementDetail`。
  Future<ShuAnnouncementDetail> parseDetail(
    Uint8List body, {
    required Uri url,
    String fallbackTitle = '',
    String fallbackDateText = '',
  }) async {
    final result = await _send(_detailRequest, <Object?>[
      body,
      url,
      fallbackTitle,
      fallbackDateText,
    ]);
    return result! as ShuAnnouncementDetail;
  }

  /// 收掉后台 isolate；之后再用这个对象会抛 [ShuAnnouncementException]。
  void close() {
    _closed = true;
    final isolate = _isolate;
    _events?.close();
    _exit?.close();
    _isolate = null;
    _events = null;
    _exit = null;
    _channel = null;
    // 那条 isolate 自己的退出回调随后会到，让它别再碰这几个字段。
    _generation++;
    isolate?.kill(priority: Isolate.immediate);
    _failPending('解析服务已关闭');
  }

  Future<Object?> _send(int kind, List<Object?> arguments) async {
    if (_closed) throw const ShuAnnouncementException('解析服务已关闭');
    final port = await _channelOf();
    // 起 isolate 的路上可能已经被 close 了。
    if (_closed) throw const ShuAnnouncementException('解析服务已关闭');
    final id = _nextId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    try {
      port.send(<Object?>[id, kind, ...arguments]);
    } on Object {
      _pending.remove(id);
      rethrow;
    }
    return completer.future;
  }

  Future<SendPort> _channelOf() {
    final existing = _channel;
    if (existing != null) return existing;
    final starting = _start();
    _channel = starting;
    return starting;
  }

  Future<SendPort> _start() async {
    final generation = ++_generation;
    final events = ReceivePort();
    final exit = ReceivePort();
    final ready = Completer<SendPort>();
    Isolate? isolate;
    var released = false;

    void release(String reason) {
      if (released) return;
      released = true;
      events.close();
      exit.close();
      isolate?.kill(priority: Isolate.immediate);
      if (generation == _generation) {
        _channel = null;
        _isolate = null;
        _events = null;
        _exit = null;
      }
      if (!ready.isCompleted) {
        ready.completeError(ShuAnnouncementException(reason));
      }
      _failPending(reason);
    }

    events.listen((message) {
      // 第一条永远是解析 isolate 自己的投递端口（握手）。
      if (message is SendPort) {
        if (!ready.isCompleted) ready.complete(message);
        return;
      }
      final response = message as List<Object?>;
      final completer = _pending.remove(response[0]! as int);
      if (completer == null || completer.isCompleted) return;
      final failure = response[2] as String?;
      if (failure == null) {
        completer.complete(response[1]);
      } else {
        completer.completeError(ShuAnnouncementException(failure));
      }
    });

    // 解析 isolate 只在自己的入口崩掉时才会走到这里；请求级的失败都在应答里。
    exit.listen((_) => release(_parserGone));

    try {
      isolate = await Isolate.spawn(
        _parserMain,
        events.sendPort,
        debugName: 'shu-announcement-parser',
      );
    } on Object {
      release(_parserGone);
      rethrow;
    }

    // 起来之前就被 close 了（或者前一条的退出回调先到了）：这条不要了。
    if (released || generation != _generation) {
      release(_parserGone);
      throw const ShuAnnouncementException(_parserGone);
    }

    _events = events;
    _exit = exit;
    _isolate = isolate;
    return ready.future;
  }

  void _failPending(String reason) {
    if (_pending.isEmpty) return;
    final waiting = _pending.values.toList(growable: false);
    _pending.clear();
    for (final completer in waiting) {
      if (!completer.isCompleted) {
        completer.completeError(ShuAnnouncementException(reason));
      }
    }
  }
}

/// 解析 isolate 的入口。
///
/// 先把自己的投递端口交给宿主（握手），然后一条条处理请求。整条消息的处理包在
/// try 里：解析失败要变成一条**带 id 的**错误应答，而不是让这条 isolate 死掉
/// —— 死掉的话宿主手上排队的请求会一起失败。
void _parserMain(SendPort host) {
  final inbox = ReceivePort();
  host.send(inbox.sendPort);
  inbox.listen((message) {
    final request = message as List<Object?>;
    final id = request[0]! as int;
    Object? result;
    String? failure;
    try {
      result = _handle(request);
    } on Object catch (error) {
      failure = '$error';
    }
    host.send(<Object?>[id, result, failure]);
  });
}

Object _handle(List<Object?> request) {
  final body = request[2]! as Uint8List;
  final html = utf8.decode(body, allowMalformed: true);
  switch (request[1]) {
    case _listRequest:
      return parseAnnouncementList(html, baseUri: request[3]! as Uri);
    case _detailRequest:
      return parseAnnouncementDetail(
        html,
        url: request[3]! as Uri,
        fallbackTitle: request[4]! as String,
        fallbackDateText: request[5]! as String,
      );
    default:
      throw ArgumentError.value(request[1], 'kind');
  }
}
