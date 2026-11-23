import 'package:zephyr/database/db.dart';
import 'package:zephyr/database/db_read.dart';
import 'package:zephyr/database/row_codec.dart';
import 'package:zephyr/object_box/model.dart';

const _followInsert =
    'INSERT INTO "ComicFollow" '
    '("uniqueKey","source","comicId","title","description","cover","creator",'
    '"titleMeta","metadata","lastChapterCount","detectedChapterCount",'
    '"hasUpdate","updateTime","deleted","createdAt","updatedAt",'
    '"schemaVersion","detectedChapterTitle") VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)';

const _followUpsert =
    'INSERT INTO "ComicFollow" '
    '("id","uniqueKey","source","comicId","title","description","cover",'
    '"creator","titleMeta","metadata","lastChapterCount",'
    '"detectedChapterCount","hasUpdate","updateTime","deleted","createdAt",'
    '"updatedAt","schemaVersion","detectedChapterTitle") '
    'VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) '
    'ON CONFLICT("id") DO UPDATE SET '
    '"uniqueKey"=excluded."uniqueKey","source"=excluded."source",'
    '"comicId"=excluded."comicId","title"=excluded."title",'
    '"description"=excluded."description","cover"=excluded."cover",'
    '"creator"=excluded."creator","titleMeta"=excluded."titleMeta",'
    '"metadata"=excluded."metadata",'
    '"lastChapterCount"=excluded."lastChapterCount",'
    '"detectedChapterCount"=excluded."detectedChapterCount",'
    '"hasUpdate"=excluded."hasUpdate","updateTime"=excluded."updateTime",'
    '"deleted"=excluded."deleted","createdAt"=excluded."createdAt",'
    '"updatedAt"=excluded."updatedAt",'
    '"schemaVersion"=excluded."schemaVersion",'
    '"detectedChapterTitle"=excluded."detectedChapterTitle"';

class ComicFollowRepository {
  final BreezeDatabase db;

  const ComicFollowRepository(this.db);

  static const String table = 'ComicFollow';

  Future<ComicFollow?> getById(int id) => runDbRead(
    db,
    sql: 'SELECT * FROM "ComicFollow" WHERE "id" = ? LIMIT 1',
    params: <Object?>[id],
    decode: _decodeFirst,
  );

  Future<ComicFollow?> getByKey(String uniqueKey) => runDbRead(
    db,
    sql: 'SELECT * FROM "ComicFollow" WHERE "uniqueKey" = ? LIMIT 1',
    params: <Object?>[uniqueKey],
    decode: _decodeFirst,
  );

  Future<List<ComicFollow>> getAll() => runDbRead(
    db,
    sql: 'SELECT * FROM "ComicFollow" ORDER BY "id"',
    decode: _decodeAll,
  );

  Future<List<ComicFollow>> listActive() => runDbRead(
    db,
    sql:
        'SELECT * FROM "ComicFollow" WHERE "deleted" = 0 '
        'ORDER BY "hasUpdate" DESC, "updateTime" DESC, "id" DESC',
    decode: _decodeAll,
  );

  Future<int> count() => runDbRead(
    db,
    sql: 'SELECT COUNT(*) AS c FROM "ComicFollow"',
    decode: countFromRows,
  );

  Future<int> put(ComicFollow value) async {
    if (value.id > 0) {
      await db.execute(_followUpsert, _params(value, includeId: true));
      return value.id;
    }
    final result = await db.execute(
      _followInsert,
      _params(value, includeId: false),
    );
    value.id = result.lastInsertId;
    return value.id;
  }

  Future<List<int>> putMany(List<ComicFollow> values) async {
    if (values.isEmpty) return const <int>[];
    return db.transaction((tx) async {
      final ids = <int>[];
      for (final value in values) {
        ids.add(await _putInTx(tx, value));
      }
      return ids;
    });
  }

  Future<int> removeAll() async {
    final result = await db.execute('DELETE FROM "ComicFollow"');
    return result.changes;
  }

  Future<int> _putInTx(DbTransaction tx, ComicFollow value) async {
    if (value.id > 0) {
      await tx.execute(_followUpsert, _params(value, includeId: true));
      return value.id;
    }
    final result = await tx.execute(
      _followInsert,
      _params(value, includeId: false),
    );
    value.id = result.lastInsertId;
    return value.id;
  }

  List<Object?> _params(ComicFollow v, {required bool includeId}) {
    return <Object?>[
      if (includeId) v.id,
      v.uniqueKey,
      v.source,
      v.comicId,
      v.title,
      v.description,
      v.cover,
      v.creator,
      v.titleMeta,
      v.metadata,
      v.lastChapterCount,
      v.detectedChapterCount,
      boolToDb(v.hasUpdate),
      dateToDb(v.updateTime),
      boolToDb(v.deleted),
      dateToDb(v.createdAt),
      dateToDb(v.updatedAt),
      v.schemaVersion,
      v.detectedChapterTitle,
    ];
  }

  static ComicFollow _decodeRow(Map<String, dynamic> row) {
    return ComicFollow.fromJson(
      normalizeRow(
        withDefaultId(row),
        dates: const <String>{'updateTime', 'createdAt', 'updatedAt'},
        bools: const <String>{'hasUpdate', 'deleted'},
      ),
    );
  }

  static List<ComicFollow> _decodeAll(List<Map<String, dynamic>> rows) =>
      rows.map(_decodeRow).toList();

  static ComicFollow? _decodeFirst(List<Map<String, dynamic>> rows) =>
      rows.isEmpty ? null : _decodeRow(rows.first);
}
