import 'package:uuid/uuid.dart';
import 'package:zephyr/database/db.dart';
import 'package:zephyr/database/db_read.dart';
import 'package:zephyr/database/row_codec.dart';
import 'package:zephyr/object_box/model.dart';

const _pluginInfoColumns =
    '"id","version","insertedAt","updatedAt","isEnabled","isDeleted","uuid",'
    '"lastLoadSuccess","lastLoadError","deletedAt","debug","debugUrl",'
    '"getInfoJson","sortOrder"';

const _pluginInfoWithScriptSelect =
    'SELECT i.*, COALESCE(s."originScript", \'\') AS "originScript", '
    'COALESCE(s."scriptUpdatedAt", 0) AS "scriptUpdatedAt" '
    'FROM "PluginInfo" i LEFT JOIN "PluginScript" s ON s."uuid" = i."uuid"';

const _pluginInfoInsert =
    'INSERT INTO "PluginInfo" '
    '("version","insertedAt","updatedAt","isEnabled","isDeleted","uuid",'
    '"lastLoadSuccess","lastLoadError","deletedAt","debug","debugUrl",'
    '"getInfoJson","sortOrder") '
    'VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)';

const _pluginInfoUpsert =
    'INSERT INTO "PluginInfo" '
    '("id","version","insertedAt","updatedAt","isEnabled","isDeleted","uuid",'
    '"lastLoadSuccess","lastLoadError","deletedAt","debug","debugUrl",'
    '"getInfoJson","sortOrder") '
    'VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?) '
    'ON CONFLICT("id") DO UPDATE SET '
    '"version"=excluded."version","insertedAt"=excluded."insertedAt",'
    '"updatedAt"=excluded."updatedAt","isEnabled"=excluded."isEnabled",'
    '"isDeleted"=excluded."isDeleted","uuid"=excluded."uuid",'
    '"lastLoadSuccess"=excluded."lastLoadSuccess",'
    '"lastLoadError"=excluded."lastLoadError","deletedAt"=excluded."deletedAt",'
    '"debug"=excluded."debug","debugUrl"=excluded."debugUrl",'
    '"getInfoJson"=excluded."getInfoJson","sortOrder"=excluded."sortOrder"';

// 内容不变时不更新：revision 是字节码缓存的键，同步/备份重写同一脚本
// 不应让缓存失效。
const _pluginScriptUpsert =
    'INSERT INTO "PluginScript" '
    '("uuid","originScript","revision","scriptUpdatedAt") '
    'VALUES (?,?,?,?) '
    'ON CONFLICT("uuid") DO UPDATE SET '
    '"originScript"=excluded."originScript","revision"=excluded."revision",'
    '"scriptUpdatedAt"=excluded."scriptUpdatedAt" '
    'WHERE "originScript" <> excluded."originScript"';

const _pluginScriptDelete = 'DELETE FROM "PluginScript" WHERE "uuid" = ?';

const _pluginConfigInsert =
    'INSERT INTO "PluginConfig" ("name","config") VALUES (?,?)';

const _pluginConfigUpsert =
    'INSERT INTO "PluginConfig" ("id","name","config") VALUES (?,?,?) '
    'ON CONFLICT("id") DO UPDATE SET '
    '"name"=excluded."name","config"=excluded."config"';

class PluginRepository {
  final BreezeDatabase db;

  const PluginRepository(this.db);

  static const String infoTable = 'PluginInfo';
  static const String configTable = 'PluginConfig';

  /// 只读元数据，不 JOIN 脚本表。列表、排序、启用状态等 UI 查询走这里。
  Future<List<PluginInfo>> listInfos() => runDbRead(
    db,
    sql: 'SELECT $_pluginInfoColumns FROM "PluginInfo" ORDER BY "id"',
    decode: _decodeInfos,
  );

  /// 同步/备份等确实需要脚本的场景：一次性把脚本和元数据取回。
  ///
  /// 脚本是大字段（单个可达数百 KB），整条查询放进后台 isolate，
  /// 行解码不占 UI isolate；已在后台 isolate 内时直接执行。
  Future<List<PluginInfo>> listInfosWithScripts() => runDbReadInWorker(
    db,
    sql: '$_pluginInfoWithScriptSelect ORDER BY i."id"',
    decode: _decodeInfos,
  );

  Future<PluginInfo?> getInfoById(int id) => runDbRead(
    db,
    sql: 'SELECT $_pluginInfoColumns FROM "PluginInfo" WHERE "id" = ? LIMIT 1',
    params: <Object?>[id],
    decode: _decodeInfoFirst,
  );

  Future<PluginInfo?> getInfoByUuid(String uuid) => runDbRead(
    db,
    sql:
        'SELECT $_pluginInfoColumns FROM "PluginInfo" '
        'WHERE "uuid" = ? LIMIT 1',
    params: <Object?>[uuid],
    decode: _decodeInfoFirst,
  );

  /// 元数据 + 脚本；仅在需要执行/比较脚本时使用。
  Future<PluginInfo?> getInfoWithScriptByUuid(String uuid) => runDbReadInWorker(
    db,
    sql: '$_pluginInfoWithScriptSelect WHERE i."uuid" = ? LIMIT 1',
    params: <Object?>[uuid],
    decode: _decodeInfoFirst,
  );

  /// 按 uuid 读取脚本；不存在或为空时返回空串。
  ///
  /// 脚本是大字段，读取与行解码放进后台 isolate。
  Future<String> getScriptByUuid(String uuid) => runDbReadInWorker(
    db,
    sql: 'SELECT "originScript" FROM "PluginScript" WHERE "uuid" = ? LIMIT 1',
    params: <Object?>[uuid],
    decode: _decodeScript,
  );

  /// 当前脚本 revision；字节码缓存按它命名，脚本一变 revision 就变。
  Future<String> getScriptRevisionByUuid(String uuid) => runDbRead(
    db,
    sql: 'SELECT "revision" FROM "PluginScript" WHERE "uuid" = ? LIMIT 1',
    params: <Object?>[uuid],
    decode: _decodeRevision,
  );

  Future<List<PluginInfo>> listDeletedInfos() => runDbRead(
    db,
    sql:
        'SELECT $_pluginInfoColumns FROM "PluginInfo" '
        'WHERE "isDeleted" = 1 ORDER BY "id"',
    decode: _decodeInfos,
  );

  /// 只写元数据，不触碰 [PluginScript]；用于启用状态、getInfo 缓存等更新。
  Future<int> putInfo(PluginInfo value) async {
    if (value.id > 0) {
      await db.execute(_pluginInfoUpsert, _infoParams(value, includeId: true));
      return value.id;
    }
    final result = await db.execute(
      _pluginInfoInsert,
      _infoParams(value, includeId: false),
    );
    value.id = result.lastInsertId;
    return value.id;
  }

  /// 元数据 + 脚本一起写；安装、更新、恢复等场景使用。
  Future<int> putInfoWithScript(PluginInfo value) {
    return db.transaction((tx) async {
      final id = await _putInfoInTx(tx, value);
      await _putScriptInTx(
        tx,
        value.uuid,
        value.originScript,
        _scriptUpdatedAtMs(value),
      );
      return id;
    });
  }

  /// 只写元数据；脚本保持不变。
  Future<List<int>> putInfos(List<PluginInfo> values) async {
    if (values.isEmpty) return const <int>[];
    return db.transaction((tx) async {
      final ids = <int>[];
      for (final value in values) {
        ids.add(await _putInfoInTx(tx, value));
      }
      return ids;
    });
  }

  /// 元数据 + 脚本一起写；同步、备份恢复等场景使用。
  Future<List<int>> putInfosWithScripts(List<PluginInfo> values) async {
    if (values.isEmpty) return const <int>[];
    return db.transaction((tx) async {
      final ids = <int>[];
      for (final value in values) {
        ids.add(await _putInfoInTx(tx, value));
        await _putScriptInTx(
          tx,
          value.uuid,
          value.originScript,
          _scriptUpdatedAtMs(value),
        );
      }
      return ids;
    });
  }

  Future<int> putScript(String uuid, String originScript) async {
    if (originScript.trim().isEmpty) {
      return removeScriptByUuid(uuid);
    }
    final result = await db.execute(_pluginScriptUpsert, <Object?>[
      uuid,
      originScript,
      const Uuid().v4(),
      DateTime.now().toUtc().millisecondsSinceEpoch,
    ]);
    return result.changes;
  }

  Future<int> removeScriptByUuid(String uuid) async {
    final result = await db.execute(_pluginScriptDelete, <Object?>[uuid]);
    return result.changes;
  }

  Future<int> removeInfoById(int id) async {
    return db.transaction((tx) async {
      await tx.execute(
        'DELETE FROM "PluginScript" WHERE "uuid" IN '
        '(SELECT "uuid" FROM "PluginInfo" WHERE "id" = ?)',
        <Object?>[id],
      );
      final result = await tx.execute(
        'DELETE FROM "PluginInfo" WHERE "id" = ?',
        <Object?>[id],
      );
      return result.changes;
    });
  }

  Future<int> removeInfosByIds(List<int> ids) async {
    if (ids.isEmpty) return 0;
    final marks = List.filled(ids.length, '?').join(',');
    return db.transaction((tx) async {
      await tx.execute(
        'DELETE FROM "PluginScript" WHERE "uuid" IN '
        '(SELECT "uuid" FROM "PluginInfo" WHERE "id" IN ($marks))',
        ids,
      );
      final result = await tx.execute(
        'DELETE FROM "PluginInfo" WHERE "id" IN ($marks)',
        ids,
      );
      return result.changes;
    });
  }

  Future<int> removeAllInfos() async {
    return db.transaction((tx) async {
      await tx.execute('DELETE FROM "PluginScript"');
      final result = await tx.execute('DELETE FROM "PluginInfo"');
      return result.changes;
    });
  }

  Future<List<PluginConfig>> listConfigs() => runDbRead(
    db,
    sql: 'SELECT * FROM "PluginConfig" ORDER BY "id"',
    decode: _decodeConfigs,
  );

  Future<PluginConfig?> getConfigById(int id) => runDbRead(
    db,
    sql: 'SELECT * FROM "PluginConfig" WHERE "id" = ? LIMIT 1',
    params: <Object?>[id],
    decode: _decodeConfigFirst,
  );

  Future<PluginConfig?> getConfigByName(String name) => runDbRead(
    db,
    sql: 'SELECT * FROM "PluginConfig" WHERE "name" = ? LIMIT 1',
    params: <Object?>[name],
    decode: _decodeConfigFirst,
  );

  Future<int> putConfig(PluginConfig value) async {
    if (value.id > 0) {
      await db.execute(_pluginConfigUpsert, <Object?>[
        value.id,
        value.name,
        value.config,
      ]);
      return value.id;
    }
    final result = await db.execute(_pluginConfigInsert, <Object?>[
      value.name,
      value.config,
    ]);
    value.id = result.lastInsertId;
    return value.id;
  }

  Future<List<int>> putConfigs(List<PluginConfig> values) async {
    if (values.isEmpty) return const <int>[];
    return db.transaction((tx) async {
      final ids = <int>[];
      for (final value in values) {
        ids.add(await _putConfigInTx(tx, value));
      }
      return ids;
    });
  }

  Future<int> removeConfigByIds(List<int> ids) async {
    if (ids.isEmpty) return 0;
    final marks = List.filled(ids.length, '?').join(',');
    final result = await db.execute(
      'DELETE FROM "PluginConfig" WHERE "id" IN ($marks)',
      ids,
    );
    return result.changes;
  }

  Future<int> removeConfigByName(String name) async {
    final result = await db.execute(
      'DELETE FROM "PluginConfig" WHERE "name" = ?',
      <Object?>[name],
    );
    return result.changes;
  }

  Future<int> removeAllConfigs() async {
    final result = await db.execute('DELETE FROM "PluginConfig"');
    return result.changes;
  }

  Future<int> _putInfoInTx(DbTransaction tx, PluginInfo value) async {
    if (value.id > 0) {
      await tx.execute(_pluginInfoUpsert, _infoParams(value, includeId: true));
      return value.id;
    }
    final result = await tx.execute(
      _pluginInfoInsert,
      _infoParams(value, includeId: false),
    );
    value.id = result.lastInsertId;
    return value.id;
  }

  Future<void> _putScriptInTx(
    DbTransaction tx,
    String uuid,
    String originScript,
    int scriptUpdatedAt,
  ) async {
    if (originScript.trim().isEmpty) {
      await tx.execute(_pluginScriptDelete, <Object?>[uuid]);
      return;
    }
    await tx.execute(_pluginScriptUpsert, <Object?>[
      uuid,
      originScript,
      const Uuid().v4(),
      scriptUpdatedAt,
    ]);
  }

  /// 显式时间优先；安装/更新等新建对象用 [PluginInfo.updatedAt] 兜底。
  static int _scriptUpdatedAtMs(PluginInfo value) {
    if (value.scriptUpdatedAt > 0) {
      return value.scriptUpdatedAt;
    }
    return value.updatedAt.toUtc().millisecondsSinceEpoch;
  }

  List<Object?> _infoParams(PluginInfo v, {required bool includeId}) {
    return <Object?>[
      if (includeId) v.id,
      v.version,
      dateToDb(v.insertedAt),
      dateToDb(v.updatedAt),
      boolToDb(v.isEnabled),
      boolToDb(v.isDeleted),
      v.uuid,
      boolToDb(v.lastLoadSuccess),
      v.lastLoadError,
      dateToDb(v.deletedAt),
      boolToDb(v.debug),
      v.debugUrl,
      v.getInfoJson,
      v.sortOrder,
    ];
  }

  Future<int> _putConfigInTx(DbTransaction tx, PluginConfig value) async {
    if (value.id > 0) {
      await tx.execute(_pluginConfigUpsert, <Object?>[
        value.id,
        value.name,
        value.config,
      ]);
      return value.id;
    }
    final result = await tx.execute(_pluginConfigInsert, <Object?>[
      value.name,
      value.config,
    ]);
    value.id = result.lastInsertId;
    return value.id;
  }

  static PluginInfo _decodeInfo(Map<String, dynamic> row) {
    return PluginInfo.fromJson(
      normalizeRow(
        withDefaultId(row),
        dates: const <String>{'insertedAt', 'updatedAt'},
        nullableDates: const <String>{'deletedAt'},
        bools: const <String>{
          'isEnabled',
          'isDeleted',
          'lastLoadSuccess',
          'debug',
        },
      ),
    );
  }

  static List<PluginInfo> _decodeInfos(List<Map<String, dynamic>> rows) =>
      rows.map(_decodeInfo).toList();

  static String _decodeScript(List<Map<String, dynamic>> rows) {
    if (rows.isEmpty) return '';
    return rows.first['originScript'] as String? ?? '';
  }

  static String _decodeRevision(List<Map<String, dynamic>> rows) {
    if (rows.isEmpty) return '';
    return rows.first['revision'] as String? ?? '';
  }

  static PluginInfo? _decodeInfoFirst(List<Map<String, dynamic>> rows) =>
      rows.isEmpty ? null : _decodeInfo(rows.first);

  static PluginConfig _decodeConfig(Map<String, dynamic> row) {
    return PluginConfig.fromJson(withDefaultId(row));
  }

  static List<PluginConfig> _decodeConfigs(List<Map<String, dynamic>> rows) =>
      rows.map(_decodeConfig).toList();

  static PluginConfig? _decodeConfigFirst(List<Map<String, dynamic>> rows) =>
      rows.isEmpty ? null : _decodeConfig(rows.first);
}
