import 'dart:convert';

import 'package:zephyr/database/db.dart';
import 'package:zephyr/database/db_read.dart';
import 'package:zephyr/database/row_codec.dart';
import 'package:zephyr/object_box/model.dart';

const _taskInsert =
    'INSERT INTO "DownloadTask" '
    '("isDownloading","comicId","comicName","isCompleted","status",'
    '"dbTaskInfoStr") VALUES (?,?,?,?,?,?)';

const _taskUpsert =
    'INSERT INTO "DownloadTask" '
    '("id","isDownloading","comicId","comicName","isCompleted","status",'
    '"dbTaskInfoStr") VALUES (?,?,?,?,?,?,?) '
    'ON CONFLICT("id") DO UPDATE SET '
    '"isDownloading"=excluded."isDownloading","comicId"=excluded."comicId",'
    '"comicName"=excluded."comicName","isCompleted"=excluded."isCompleted",'
    '"status"=excluded."status","dbTaskInfoStr"=excluded."dbTaskInfoStr"';

// 与 UnifiedComicDownloadRepository / ComicLinkRepository 的列定义保持一致。
// 那两个仓库各自开启事务，下载完成时“记录 + 根目录链接”必须原子提交，
// 所以这里保留一份只用于该事务的 SQL。
const _downloadInsert =
    'INSERT INTO "UnifiedComicDownload" '
    '("uniqueKey","source","comicId","title","description","storageRoot",'
    '"createdAt","updatedAt","downloadedAt","deleted","schemaVersion",'
    '"totalViews","totalLikes","totalComments","isFavourite","isLiked",'
    '"allowComment","allowLike","allowFavorite","allowDownload","cover",'
    '"creator","titleMeta","metadata","chapters","detailJson","titleOverride",'
    '"coverOverride") VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)';

const _downloadUpsert =
    'INSERT INTO "UnifiedComicDownload" '
    '("id","uniqueKey","source","comicId","title","description","storageRoot",'
    '"createdAt","updatedAt","downloadedAt","deleted","schemaVersion",'
    '"totalViews","totalLikes","totalComments","isFavourite","isLiked",'
    '"allowComment","allowLike","allowFavorite","allowDownload","cover",'
    '"creator","titleMeta","metadata","chapters","detailJson","titleOverride",'
    '"coverOverride") VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) '
    'ON CONFLICT("id") DO UPDATE SET '
    '"uniqueKey"=excluded."uniqueKey","source"=excluded."source",'
    '"comicId"=excluded."comicId","title"=excluded."title",'
    '"description"=excluded."description","storageRoot"=excluded."storageRoot",'
    '"createdAt"=excluded."createdAt","updatedAt"=excluded."updatedAt",'
    '"downloadedAt"=excluded."downloadedAt","deleted"=excluded."deleted",'
    '"schemaVersion"=excluded."schemaVersion","totalViews"=excluded."totalViews",'
    '"totalLikes"=excluded."totalLikes","totalComments"=excluded."totalComments",'
    '"isFavourite"=excluded."isFavourite","isLiked"=excluded."isLiked",'
    '"allowComment"=excluded."allowComment","allowLike"=excluded."allowLike",'
    '"allowFavorite"=excluded."allowFavorite","allowDownload"=excluded."allowDownload",'
    '"cover"=excluded."cover","creator"=excluded."creator",'
    '"titleMeta"=excluded."titleMeta","metadata"=excluded."metadata",'
    '"chapters"=excluded."chapters","detailJson"=excluded."detailJson",'
    '"titleOverride"=excluded."titleOverride","coverOverride"=excluded."coverOverride"';

const _linkInsert =
    'INSERT INTO "ComicLink" '
    '("uniqueKey","typeData","versionVectorJson","deletedAt","createdAt",'
    '"updatedAt","comicUniqueKey","folderSyncId") VALUES (?,?,?,?,?,?,?,?)';

const _linkUpsert =
    'INSERT INTO "ComicLink" '
    '("id","uniqueKey","typeData","versionVectorJson","deletedAt","createdAt",'
    '"updatedAt","comicUniqueKey","folderSyncId") VALUES (?,?,?,?,?,?,?,?,?) '
    'ON CONFLICT("id") DO UPDATE SET '
    '"uniqueKey"=excluded."uniqueKey","typeData"=excluded."typeData",'
    '"versionVectorJson"=excluded."versionVectorJson",'
    '"deletedAt"=excluded."deletedAt","createdAt"=excluded."createdAt",'
    '"updatedAt"=excluded."updatedAt",'
    '"comicUniqueKey"=excluded."comicUniqueKey",'
    '"folderSyncId"=excluded."folderSyncId"';

class DownloadTaskRepository {
  final BreezeDatabase db;

  const DownloadTaskRepository(this.db);

  static const String table = 'DownloadTask';

  Future<DownloadTask?> getById(int id) => runDbRead(
    db,
    sql: 'SELECT * FROM "DownloadTask" WHERE "id" = ? LIMIT 1',
    params: <Object?>[id],
    decode: _decodeFirst,
  );

  Future<List<DownloadTask>> getAll() => runDbRead(
    db,
    sql: 'SELECT * FROM "DownloadTask" ORDER BY "id"',
    decode: _decodeAll,
  );

  Future<List<DownloadTask>> listIncomplete() => runDbRead(
    db,
    sql: 'SELECT * FROM "DownloadTask" WHERE "isCompleted" = 0 ORDER BY "id"',
    decode: _decodeAll,
  );

  Future<List<DownloadTask>> listCompleted() => runDbRead(
    db,
    sql: 'SELECT * FROM "DownloadTask" WHERE "isCompleted" = 1 ORDER BY "id"',
    decode: _decodeAll,
  );

  Future<List<DownloadTask>> listByComicId(String comicId) => runDbRead(
    db,
    sql: 'SELECT * FROM "DownloadTask" WHERE "comicId" = ? ORDER BY "id"',
    params: <Object?>[comicId],
    decode: _decodeAll,
  );

  Future<int> count() => runDbRead(
    db,
    sql: 'SELECT COUNT(*) AS c FROM "DownloadTask"',
    decode: countFromRows,
  );

  /// 未完成任务数（`isCompleted = 0`），下载队列长度用。
  Future<int> countIncomplete() => runDbRead(
    db,
    sql: 'SELECT COUNT(*) AS c FROM "DownloadTask" WHERE "isCompleted" = 0',
    decode: countFromRows,
  );

  Future<int> put(DownloadTask value) async {
    if (value.id > 0) {
      await db.execute(_taskUpsert, _params(value, includeId: true));
      return value.id;
    }
    final result = await db.execute(
      _taskInsert,
      _params(value, includeId: false),
    );
    value.id = result.lastInsertId;
    return value.id;
  }

  Future<List<int>> putMany(List<DownloadTask> values) async {
    if (values.isEmpty) return const <int>[];
    return db.transaction((tx) async {
      final ids = <int>[];
      for (final value in values) {
        ids.add(await _putInTx(tx, value));
      }
      return ids;
    });
  }

  Future<int> removeById(int id) async {
    final result = await db.execute(
      'DELETE FROM "DownloadTask" WHERE "id" = ?',
      <Object?>[id],
    );
    return result.changes;
  }

  Future<int> removeByIds(List<int> ids) async {
    if (ids.isEmpty) return 0;
    final marks = List.filled(ids.length, '?').join(',');
    final result = await db.execute(
      'DELETE FROM "DownloadTask" WHERE "id" IN ($marks)',
      ids,
    );
    return result.changes;
  }

  Future<int> removeAll() async {
    final result = await db.execute('DELETE FROM "DownloadTask"');
    return result.changes;
  }

  /// 下载记录 + 根目录下载链接同事务提交。
  ///
  /// 下载完成时两者必须原子落库：记录写成功但链接缺失会让书架看不到这本
  /// 下载，链接写成功但记录缺失则是悬空链接。旧实现靠同一个 ObjectBox
  /// 事务保证，这里用 [BreezeDatabase.transaction] 等价替换。
  /// 链接已存在且未软删除时不动它（与 `ComicLinkService.addComic` 一致）。
  Future<int> saveDownloadRecordWithRootLink({
    required UnifiedComicDownload record,
    required String linkUniqueKey,
    required String linkComicKey,
    required String deviceId,
  }) async {
    return db.transaction((tx) async {
      final int recordId;
      if (record.id > 0) {
        await tx.execute(
          _downloadUpsert,
          _downloadParams(record, includeId: true),
        );
        recordId = record.id;
      } else {
        final result = await tx.execute(
          _downloadInsert,
          _downloadParams(record, includeId: false),
        );
        record.id = result.lastInsertId;
        recordId = record.id;
      }

      final nowMs = record.updatedAt.millisecondsSinceEpoch;
      final rows = await tx.query(
        'SELECT * FROM "ComicLink" WHERE "uniqueKey" = ? LIMIT 1',
        <Object?>[linkUniqueKey],
      );
      if (rows.isEmpty) {
        await tx.execute(_linkInsert, <Object?>[
          linkUniqueKey,
          ComicFolderType.download.name,
          jsonEncode(<String, int>{deviceId: 1}),
          null,
          nowMs,
          nowMs,
          linkComicKey,
          null,
        ]);
      } else {
        final link = ComicLink.fromJson(withDefaultId(rows.first));
        if (link.deletedAt != null) {
          link
            ..deletedAt = null
            ..createdAt = nowMs
            ..updatedAt = nowMs
            ..versionVectorJson = _bumpLinkVersionVector(
              link.versionVectorJson,
              deviceId,
            );
          await tx.execute(_linkUpsert, <Object?>[
            link.id,
            link.uniqueKey,
            link.typeData,
            link.versionVectorJson,
            link.deletedAt,
            link.createdAt,
            link.updatedAt,
            link.comicUniqueKey,
            link.folderSyncId,
          ]);
        }
      }
      return recordId;
    });
  }

  Stream<List<DownloadTask>> watchIncomplete() async* {
    yield await listIncomplete();
    yield* db.changes
        .where((tables) => tables.contains(table))
        .asyncMap((_) => listIncomplete());
  }

  Stream<List<DownloadTask>> watchCompleted() async* {
    yield await listCompleted();
    yield* db.changes
        .where((tables) => tables.contains(table))
        .asyncMap((_) => listCompleted());
  }

  Future<int> _putInTx(DbTransaction tx, DownloadTask value) async {
    if (value.id > 0) {
      await tx.execute(_taskUpsert, _params(value, includeId: true));
      return value.id;
    }
    final result = await tx.execute(
      _taskInsert,
      _params(value, includeId: false),
    );
    value.id = result.lastInsertId;
    return value.id;
  }

  List<Object?> _params(DownloadTask v, {required bool includeId}) {
    return <Object?>[
      if (includeId) v.id,
      boolToDb(v.isDownloading),
      v.comicId,
      v.comicName,
      boolToDb(v.isCompleted),
      v.status,
      v.dbTaskInfoStr,
    ];
  }

  List<Object?> _downloadParams(
    UnifiedComicDownload v, {
    required bool includeId,
  }) {
    return <Object?>[
      if (includeId) v.id,
      v.uniqueKey,
      v.source,
      v.comicId,
      v.title,
      v.description,
      v.storageRoot,
      dateToDb(v.createdAt),
      dateToDb(v.updatedAt),
      dateToDb(v.downloadedAt),
      boolToDb(v.deleted),
      v.schemaVersion,
      v.totalViews,
      v.totalLikes,
      v.totalComments,
      boolToDb(v.isFavourite),
      boolToDb(v.isLiked),
      boolToDb(v.allowComment),
      boolToDb(v.allowLike),
      boolToDb(v.allowFavorite),
      boolToDb(v.allowDownload),
      v.cover,
      v.creator,
      v.titleMeta,
      v.metadata,
      v.chapters,
      v.detailJson,
      v.titleOverride,
      v.coverOverride,
    ];
  }

  static DownloadTask _decodeRow(Map<String, dynamic> row) {
    return DownloadTask.fromJson(
      normalizeRow(
        withDefaultId(row),
        bools: const <String>{'isDownloading', 'isCompleted'},
      ),
    );
  }

  static List<DownloadTask> _decodeAll(List<Map<String, dynamic>> rows) =>
      rows.map(_decodeRow).toList();

  static DownloadTask? _decodeFirst(List<Map<String, dynamic>> rows) =>
      rows.isEmpty ? null : _decodeRow(rows.first);
}

String _bumpLinkVersionVector(String raw, String deviceId) {
  try {
    final map = Map<String, dynamic>.from(jsonDecode(raw) as Map);
    map[deviceId] = ((map[deviceId] as num?) ?? 0).toInt() + 1;
    return jsonEncode(map);
  } catch (_) {
    return jsonEncode(<String, int>{deviceId: 1});
  }
}
