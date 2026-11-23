/// 第二层数据库包装：异步 SQL、事务、参数归一化、表变更流。
///
/// SQL 由各业务仓库直接书写；这里不做 schema 反射，也不认识实体。
/// 第一层 Rust 接口见 `lib/src/rust/api/database.dart`（FRB 生成）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:zephyr/src/rust/api/database.dart' as rust;
import 'package:zephyr/util/rust/rust_loader.dart';

const Symbol _txZoneKey = #breezeDatabaseTransaction;

class DbWriteResult {
  final int changes;
  final int lastInsertId;

  const DbWriteResult(this.changes, this.lastInsertId);

  @override
  String toString() => 'DbWriteResult(changes: $changes, id: $lastInsertId)';
}

/// 打开一个 SQLite 文件。调用方负责执行 schema 与数据迁移 SQL。
class BreezeDatabase {
  final int handle;

  BreezeDatabase._(this.handle);

  /// 用已打开的 Rust 侧 handle 构造包装（供 worker isolate 复用同一连接）。
  BreezeDatabase.fromHandle(this.handle);

  static Future<BreezeDatabase> open(String path) async {
    await initRustLib();
    final handle = await rust.dbOpen(path: path);
    return BreezeDatabase._(handle);
  }

  bool get inTransaction => Zone.current[_txZoneKey] is DbTransaction;

  /// 当前调用应使用的连接句柄：事务回调内为事务连接，否则为主连接。
  ///
  /// 把读取放进后台 isolate 时（[runDbReadInWorker]）后台 isolate 无法继承
  /// 调用方的 Zone，因此需要把有效句柄显式带过去，保证事务内的读取仍走事务连接。
  int get activeHandle {
    final tx = Zone.current[_txZoneKey];
    return tx is DbTransaction ? tx.handle : handle;
  }

  /// 查询并原样返回 JSON 字符串（第一层形态）。
  Future<String> queryJson(String sql, [List<Object?> params = const []]) {
    final tx = Zone.current[_txZoneKey];
    if (tx is DbTransaction) return tx.queryJson(sql, params);
    return rust.dbQuery(
      handle: handle,
      sqlText: sql,
      paramsJson: _encodeParams(params),
    );
  }

  Future<List<Map<String, dynamic>>> query(
    String sql, [
    List<Object?> params = const [],
  ]) async {
    final text = await queryJson(sql, params);
    final decoded = jsonDecode(text);
    if (decoded is! List) {
      throw StateError('dbQuery returned ${decoded.runtimeType}');
    }
    return <Map<String, dynamic>>[
      for (final row in decoded) Map<String, dynamic>.from(row as Map),
    ];
  }

  Future<DbWriteResult> execute(
    String sql, [
    List<Object?> params = const [],
  ]) async {
    final tx = Zone.current[_txZoneKey];
    if (tx is DbTransaction) return tx.execute(sql, params);
    final text = await rust.dbExecute(
      handle: handle,
      sqlText: sql,
      paramsJson: _encodeParams(params),
    );
    final decoded = jsonDecode(text) as Map<String, dynamic>;
    return DbWriteResult(
      (decoded['changes'] as num).toInt(),
      (decoded['lastInsertId'] as num).toInt(),
    );
  }

  Future<void> executeScript(String sql) {
    final tx = Zone.current[_txZoneKey];
    if (tx is DbTransaction) return tx.executeScript(sql);
    return rust.dbExecuteScript(handle: handle, sqlText: sql);
  }

  Future<DbTransaction> begin({bool write = true}) async {
    final tx = await rust.dbBegin(handle: handle, write: write);
    return DbTransaction._(this, tx);
  }

  /// 自动提交/回滚的事务包装。
  ///
  /// 事务句柄放在当前 Zone 中：回调内所有 repository / `db.query` 调用都会
  /// 自动路由到事务连接，嵌套的 repo `putMany` 也不会另开事务或死锁。
  Future<T> transaction<T>(
    Future<T> Function(DbTransaction tx) action, {
    bool write = true,
  }) async {
    final current = Zone.current[_txZoneKey];
    if (current is DbTransaction) return action(current);

    final tx = await begin(write: write);
    try {
      final value = await runZoned(
        () => action(tx),
        zoneValues: <Object?, Object?>{_txZoneKey: tx},
      );
      await tx.commit();
      return value;
    } catch (_) {
      await tx.rollback();
      rethrow;
    }
  }

  late final Stream<Set<String>> changes = rust
      .dbWatchChanges(handle: handle)
      .map((tables) => tables.toSet())
      .asBroadcastStream();

  Future<void> close() => rust.dbClose(handle: handle);
}

class DbTransaction {
  final BreezeDatabase db;
  final int handle;
  bool _finished = false;

  DbTransaction._(this.db, this.handle);

  Future<String> queryJson(String sql, [List<Object?> params = const []]) {
    return rust.dbQuery(
      handle: handle,
      sqlText: sql,
      paramsJson: _encodeParams(params),
    );
  }

  Future<List<Map<String, dynamic>>> query(
    String sql, [
    List<Object?> params = const [],
  ]) async {
    final text = await queryJson(sql, params);
    final decoded = jsonDecode(text);
    if (decoded is! List) {
      throw StateError('dbQuery returned ${decoded.runtimeType}');
    }
    return <Map<String, dynamic>>[
      for (final row in decoded) Map<String, dynamic>.from(row as Map),
    ];
  }

  Future<DbWriteResult> execute(
    String sql, [
    List<Object?> params = const [],
  ]) async {
    final text = await rust.dbExecute(
      handle: handle,
      sqlText: sql,
      paramsJson: _encodeParams(params),
    );
    final decoded = jsonDecode(text) as Map<String, dynamic>;
    return DbWriteResult(
      (decoded['changes'] as num).toInt(),
      (decoded['lastInsertId'] as num).toInt(),
    );
  }

  Future<void> executeScript(String sql) =>
      rust.dbExecuteScript(handle: handle, sqlText: sql);

  Future<void> commit() async {
    if (_finished) return;
    _finished = true;
    await rust.dbCommit(tx: handle);
  }

  Future<void> rollback() async {
    if (_finished) return;
    _finished = true;
    await rust.dbRollback(tx: handle);
  }
}

String _encodeParams(List<Object?> params) {
  if (params.isEmpty) return '[]';
  return jsonEncode(params.map(_normalizeParam).toList(growable: false));
}

Object? _normalizeParam(Object? value) {
  if (value is DateTime) return value.toUtc().millisecondsSinceEpoch;
  if (value is List || value is Map) return jsonEncode(value);
  return value;
}
