import 'package:zephyr/database/db.dart';
import 'package:zephyr/database/migration/legacy_columns.dart';
import 'package:zephyr/database/db_read.dart';
import 'package:zephyr/database/row_codec.dart';
import 'package:zephyr/object_box/model.dart';

/// 旧 Bika/Jm 表只用于 v1→v2 迁移和数据备份恢复，不再参与新业务。
class LegacyComicRepository {
  final BreezeDatabase db;

  const LegacyComicRepository(this.db);

  Future<List<BikaComicHistory>> listBikaHistories() => runDbRead(
    db,
    sql: 'SELECT * FROM "BikaComicHistory" ORDER BY "id"',
    decode: _decodeBikaHistories,
  );

  Future<List<BikaComicDownload>> listBikaDownloads() => runDbRead(
    db,
    sql: 'SELECT * FROM "BikaComicDownload" ORDER BY "id"',
    decode: _decodeBikaDownloads,
  );

  Future<List<JmFavorite>> listJmFavorites() => runDbRead(
    db,
    sql: 'SELECT * FROM "JmFavorite" ORDER BY "id"',
    decode: _decodeJmFavorites,
  );

  Future<List<JmHistory>> listJmHistories() => runDbRead(
    db,
    sql: 'SELECT * FROM "JmHistory" ORDER BY "id"',
    decode: _decodeJmHistories,
  );

  Future<List<JmDownload>> listJmDownloads() => runDbRead(
    db,
    sql: 'SELECT * FROM "JmDownload" ORDER BY "id"',
    decode: _decodeJmDownloads,
  );

  Future<int> clearBikaHistories() async =>
      (await db.execute('DELETE FROM "BikaComicHistory"')).changes;

  Future<int> clearBikaDownloads() async =>
      (await db.execute('DELETE FROM "BikaComicDownload"')).changes;

  Future<int> clearJmFavorites() async =>
      (await db.execute('DELETE FROM "JmFavorite"')).changes;

  Future<int> clearJmHistories() async =>
      (await db.execute('DELETE FROM "JmHistory"')).changes;

  Future<int> clearJmDownloads() async =>
      (await db.execute('DELETE FROM "JmDownload"')).changes;

  // ==================== 备份恢复（旧 Bika/Jm 表） ====================

  /// 从备份 JSON 恢复旧 Bika 历史表，返回写入行数。
  Future<int> restoreBikaHistories(List<Map<String, dynamic>> rows) {
    return _insertLegacyRows(
      'BikaComicHistory',
      rows,
      dates: const <String>{'updatedAt', 'createdAt', 'history'},
      bools: const <String>{
        'finished',
        'creatorVerified',
        'allowDownload',
        'allowComment',
        'isFavourite',
        'isLiked',
        'deleted',
      },
      stringLists: const <String>{'creatorCharacters', 'categories', 'tags'},
    );
  }

  Future<int> restoreBikaDownloads(List<Map<String, dynamic>> rows) {
    return _insertLegacyRows(
      'BikaComicDownload',
      rows,
      dates: const <String>{'updatedAt', 'createdAt', 'downloadTime'},
      bools: const <String>{
        'creatorVerified',
        'finished',
        'allowDownload',
        'allowComment',
        'isFavourite',
        'isLiked',
      },
      stringLists: const <String>{
        'creatorCharacters',
        'categories',
        'tags',
        'epsTitle',
      },
    );
  }

  Future<int> restoreJmFavorites(List<Map<String, dynamic>> rows) {
    return _insertLegacyRows(
      'JmFavorite',
      rows,
      dates: const <String>{'history'},
      bools: const <String>{'liked', 'isFavorite', 'isAids', 'deleted'},
      stringLists: const <String>{'author', 'tags', 'works', 'actors'},
    );
  }

  Future<int> restoreJmHistories(List<Map<String, dynamic>> rows) {
    return _insertLegacyRows(
      'JmHistory',
      rows,
      dates: const <String>{'history'},
      bools: const <String>{'liked', 'isFavorite', 'isAids', 'deleted'},
      stringLists: const <String>{'author', 'tags', 'works', 'actors'},
    );
  }

  Future<int> restoreJmDownloads(List<Map<String, dynamic>> rows) {
    return _insertLegacyRows(
      'JmDownload',
      rows,
      dates: const <String>{'downloadTime'},
      bools: const <String>{'liked', 'isFavorite', 'isAids'},
      stringLists: const <String>{
        'author',
        'tags',
        'works',
        'actors',
        'epsIds',
      },
    );
  }

  /// 按 [legacyTableColumns] 白名单写入备份行：只写备份里确实存在的列，
  /// 缺失列交给表默认值；`id` 一律丢弃，由 SQLite 重新分配。
  Future<int> _insertLegacyRows(
    String table,
    List<Map<String, dynamic>> rows, {
    Set<String> dates = const <String>{},
    Set<String> bools = const <String>{},
    Set<String> stringLists = const <String>{},
  }) async {
    if (rows.isEmpty) return 0;
    final allowed = legacyTableColumns[table];
    if (allowed == null) {
      throw ArgumentError.value(table, 'table', 'unknown legacy table');
    }
    var inserted = 0;
    await db.transaction((tx) async {
      for (final row in rows) {
        final columns = allowed
            .where(
              (column) =>
                  column != 'id' &&
                  row[column] != null &&
                  row.containsKey(column),
            )
            .toList();
        if (columns.isEmpty) continue;
        final sql =
            'INSERT INTO "$table" '
            '(${columns.map((c) => '"$c"').join(',')}) '
            'VALUES (${List.filled(columns.length, '?').join(',')})';
        await tx.execute(sql, <Object?>[
          for (final column in columns)
            _toDbValue(
              row[column],
              isDate: dates.contains(column),
              isBool: bools.contains(column),
              isList: stringLists.contains(column),
            ),
        ]);
        inserted++;
      }
    });
    return inserted;
  }

  Object _toDbValue(
    Object value, {
    required bool isDate,
    required bool isBool,
    required bool isList,
  }) {
    if (isDate) {
      if (value is DateTime) return dateToDb(value) ?? 0;
      if (value is num) return value.toInt();
      return dateToDb(DateTime.tryParse(value.toString())) ?? 0;
    }
    if (isBool) {
      if (value is bool) return boolToDb(value);
      if (value is num) return value != 0 ? 1 : 0;
      return value.toString().toLowerCase() == 'true' ? 1 : 0;
    }
    if (isList) {
      if (value is List) return stringListToDb(value.map((e) => '$e').toList());
      return value.toString();
    }
    return value;
  }

  static BikaComicHistory _decodeBikaHistory(Map<String, dynamic> row) {
    return BikaComicHistory.fromJson(
      normalizeRow(
        withDefaultId(row),
        dates: const <String>{'updatedAt', 'createdAt', 'history'},
        bools: const <String>{
          'finished',
          'creatorVerified',
          'allowDownload',
          'allowComment',
          'isFavourite',
          'isLiked',
          'deleted',
        },
        stringLists: const <String>{'creatorCharacters', 'categories', 'tags'},
      ),
    );
  }

  static BikaComicDownload _decodeBikaDownload(Map<String, dynamic> row) {
    return BikaComicDownload.fromJson(
      normalizeRow(
        withDefaultId(row),
        dates: const <String>{'updatedAt', 'createdAt', 'downloadTime'},
        bools: const <String>{
          'creatorVerified',
          'finished',
          'allowDownload',
          'allowComment',
          'isFavourite',
          'isLiked',
        },
        stringLists: const <String>{
          'creatorCharacters',
          'categories',
          'tags',
          'epsTitle',
        },
      ),
    );
  }

  static JmFavorite _decodeJmFavorite(Map<String, dynamic> row) {
    return JmFavorite.fromJson(
      normalizeRow(
        withDefaultId(row),
        dates: const <String>{'history'},
        bools: const <String>{'liked', 'isFavorite', 'isAids', 'deleted'},
        stringLists: const <String>{'author', 'tags', 'works', 'actors'},
      ),
    );
  }

  static JmHistory _decodeJmHistory(Map<String, dynamic> row) {
    return JmHistory.fromJson(
      normalizeRow(
        withDefaultId(row),
        dates: const <String>{'history'},
        bools: const <String>{'liked', 'isFavorite', 'isAids', 'deleted'},
        stringLists: const <String>{'author', 'tags', 'works', 'actors'},
      ),
    );
  }

  static JmDownload _decodeJmDownload(Map<String, dynamic> row) {
    return JmDownload.fromJson(
      normalizeRow(
        withDefaultId(row),
        dates: const <String>{'downloadTime'},
        bools: const <String>{'liked', 'isFavorite', 'isAids'},
        stringLists: const <String>{
          'author',
          'tags',
          'works',
          'actors',
          'epsIds',
        },
      ),
    );
  }

  static List<BikaComicHistory> _decodeBikaHistories(
    List<Map<String, dynamic>> rows,
  ) => rows.map(_decodeBikaHistory).toList();

  static List<BikaComicDownload> _decodeBikaDownloads(
    List<Map<String, dynamic>> rows,
  ) => rows.map(_decodeBikaDownload).toList();

  static List<JmFavorite> _decodeJmFavorites(List<Map<String, dynamic>> rows) =>
      rows.map(_decodeJmFavorite).toList();

  static List<JmHistory> _decodeJmHistories(List<Map<String, dynamic>> rows) =>
      rows.map(_decodeJmHistory).toList();

  static List<JmDownload> _decodeJmDownloads(List<Map<String, dynamic>> rows) =>
      rows.map(_decodeJmDownload).toList();
}
