import 'package:zephyr/database/db.dart';
import 'package:zephyr/util/async/worker_pool.dart';
import 'package:zephyr/util/rust/rust_loader.dart';

/// 一条「SQL 查询 + 行解码」读取，默认在当前 isolate 直接执行。
///
/// 真正的 SQL 在 Rust 线程池里跑，Dart 侧只剩参数编码与行 JSON 解码；为一条
/// 小查询单独 spawn isolate 的固定开销（debug/JIT 下可达秒级）比查询本身更贵，
/// 所以不再默认进 isolate。只有大字段/大结果集才由调用方显式走
/// [runDbReadInWorker]。
Future<R> runDbRead<R>(
  BreezeDatabase db, {
  required String sql,
  List<Object?> params = const <Object?>[],
  required R Function(List<Map<String, dynamic>> rows) decode,
}) async {
  return decode(await db.query(sql, params));
}

/// 大字段读取（插件脚本、含脚本的插件信息）：整条查询与解码放进后台 isolate。
///
/// 调度细节见 [runInIsolate]；事务内调用时把事务连接句柄带进去。
Future<R> runDbReadInWorker<R>(
  BreezeDatabase db, {
  required String sql,
  List<Object?> params = const <Object?>[],
  required R Function(List<Map<String, dynamic>> rows) decode,
}) {
  return runInIsolate<R, _DbReadTask<R>>(_queryAndDecode<R>, (
    handle: db.activeHandle,
    sql: sql,
    params: params,
    decode: decode,
  ));
}

typedef _DbReadTask<R> = ({
  int handle,
  String sql,
  List<Object?> params,
  R Function(List<Map<String, dynamic>> rows) decode,
});

Future<R> _queryAndDecode<R>(_DbReadTask<R> task) async {
  await initRustLib();
  return task.decode(
    await BreezeDatabase.fromHandle(task.handle).query(task.sql, task.params),
  );
}

/// `SELECT COUNT(*) AS c ...` 的通用解码。
int countFromRows(List<Map<String, dynamic>> rows) =>
    (rows.single['c'] as num).toInt();

/// 按 SQLite 参数上限把列表切成小块（默认 400 个占位符）。
Iterable<List<T>> chunkParams<T>(List<T> values, {int size = 400}) sync* {
  for (var start = 0; start < values.length; start += size) {
    final end = start + size < values.length ? start + size : values.length;
    yield values.sublist(start, end);
  }
}
