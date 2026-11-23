import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:worker_manager/worker_manager.dart';

bool _inWorkerTask = false;

/// 在全局 worker 池（[workerManager]）里执行耗时任务。
///
/// 池内 isolate 常驻，省掉了 `compute` 每次 spawn + JIT 预热的固定开销；
/// 参数与结果通过 `SendPort` 深拷贝（普通模型图实测毫秒级），因此适合
/// 「计算重」的任务，没必要为一条小查询单独入池。
///
/// [task] 是跨 isolate 发送的闭包，只在 worker 内执行：
///
/// - 闭包里不要访问 `main.dart` 的全局状态（`database`、`logger`、
///   `globalSetting` 等）：worker isolate 从未执行过 `main()`，这些是空的。
///   需要在 worker 里用的值（handle、参数、模型）必须在**调用方**先算好，
///   再作为闭包的捕获变量带过去。
/// - 不要捕获 `Database`、`Cubit`、`BuildContext` 等对象；worker 内用
///   `Database.fromHandle(handle)` + `initRustLib()` 重建。
/// - 已在池内时直接执行，不重复入池（池满时嵌套提交会死锁）。
Future<R> runInWorker<R>(FutureOr<R> Function() task) {
  if (_inWorkerTask) return Future<R>.sync(task);
  return workerManager.execute(() => _runWorkerTask<R>(task));
}

Future<R> _runWorkerTask<R>(FutureOr<R> Function() task) {
  _inWorkerTask = true;
  return Future<R>.sync(task);
}

/// 在后台 isolate 执行 [callback]，入参 [message]，出参 [R]。
///
/// 对外行为只有「在别的 isolate 跑完再回来」，调用方不需要感知实现：
///
/// - debug：走 [runInWorker] 的常驻 worker 池，避开 debug/断点下每次
///   新建 isolate 的固定开销（Windows debug 实测平凡 `compute` 单次约 1.7s）。
/// - release / profile：走 [compute]（内部即 `Isolate.run` + `Isolate.exit`），
///   结果零拷贝返回，大结果不付 `SendPort` 深拷贝成本。
///
/// 两条路径的传输约束相同：[callback]、[message] 与返回值都必须可跨
/// isolate 发送。用顶层/静态函数接收数据，多参数用 record 打包，不要捕获
/// `Database`、`Cubit`、`BuildContext` 等对象，任务内也没有 `main.dart` 的
/// 全局状态。池内 isolate 会被复用，任务必须是 [message] 的纯函数，不要
/// 依赖或修改 isolate 内的静态状态。
///
/// 已在 worker 内时直接执行；`compute` 分支也会在 spawned isolate 里打上
/// 同样的标记，因此任务内部嵌套的 [runInWorker] / [runInIsolate] 不会二次
/// spawn。
Future<R> runInIsolate<R, M>(ComputeCallback<M, R> callback, M message) {
  if (_inWorkerTask) return Future<R>.sync(() => callback(message));
  if (kDebugMode) {
    return runInWorker<R>(() => callback(message));
  }
  return runInIsolateSpawned(callback, message);
}

/// [runInIsolate] 的 release / profile 分支：`compute`（即 `Isolate.run` +
/// `Isolate.exit`），结果零拷贝返回。
///
/// spawned isolate 内同样打上 `_inWorkerTask` 标记，嵌套任务直接执行。
/// 单独暴露只为在 debug 测试里覆盖该分支；业务代码一律使用 [runInIsolate]。
@visibleForTesting
Future<R> runInIsolateSpawned<R, M>(ComputeCallback<M, R> callback, M message) {
  return compute<M, R>((message) {
    _inWorkerTask = true;
    return callback(message);
  }, message);
}
