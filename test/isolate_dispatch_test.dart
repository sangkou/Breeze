import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:zephyr/util/async/worker_pool.dart';

typedef _Job = ({List<int> values, String label});

Map<String, Object> _summarize(_Job job) {
  return {
    'label': job.label,
    'sum': job.values.fold<int>(0, (sum, value) => sum + value),
    'count': job.values.length,
  };
}

Future<Map<String, Object>> _summarizeAsync(_Job job) async {
  await Future<void>.delayed(const Duration(milliseconds: 1));
  return _summarize(job);
}

SendPort _controlPort(Object? _) => Isolate.current.controlPort;

Never _boom(Object? _) => throw StateError('boom');

typedef _MapJob = ({int value, int Function(int) map});

int _applyMap(_MapJob job) => job.map(job.value);

Future<({SendPort direct, SendPort nested})> _nestedPorts(Object? _) async {
  final direct = Isolate.current.controlPort;
  final nested = await runInIsolate<SendPort, Object?>(_controlPort, null);
  return (direct: direct, nested: nested);
}

void main() {
  test('泛型入参/返回值跨 isolate 传递', () async {
    final result = await runInIsolate<Map<String, Object>, _Job>(_summarize, (
      values: [1, 2, 3],
      label: 'sum',
    ));

    expect(result, {'label': 'sum', 'sum': 6, 'count': 3});
  });

  test('异步回调的结果同样展平返回', () async {
    final result = await runInIsolate<Map<String, Object>, _Job>(
      _summarizeAsync,
      (values: [4, 5], label: 'async'),
    );

    expect(result, {'label': 'async', 'sum': 9, 'count': 2});
  });

  test('debug 下调度到 worker 池，不在调用方 isolate 执行', () async {
    final workerPort = await runInIsolate<SendPort, Object?>(
      _controlPort,
      null,
    );

    expect(workerPort, isNot(equals(Isolate.current.controlPort)));
  });

  test('已在 worker 内时直接执行，不重复入池', () async {
    final ports = await runInWorker(() async {
      final direct = Isolate.current.controlPort;
      final nested = await runInIsolate<SendPort, Object?>(_controlPort, null);
      return (direct: direct, nested: nested);
    });

    expect(ports.nested, equals(ports.direct));
  });

  test('任务异常回传到调用方', () async {
    await expectLater(
      runInIsolate<void, Object?>(_boom, null),
      throwsA(isA<StateError>().having((e) => e.message, 'message', 'boom')),
    );
  });

  test('release 分支的 compute 可发送泛型回调与消息内闭包', () async {
    final result = await runInIsolateSpawned<int, _MapJob>(_applyMap, (
      value: 21,
      map: (value) => value * 2,
    ));

    expect(result, 42);
  });

  test('release 分支在 spawned isolate 内嵌套调用直接执行', () async {
    final ports =
        await runInIsolateSpawned<
          ({SendPort direct, SendPort nested}),
          Object?
        >(_nestedPorts, null);

    expect(ports.direct, isNot(equals(Isolate.current.controlPort)));
    expect(ports.nested, equals(ports.direct));
  });
}
