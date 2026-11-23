import 'dart:convert';
import 'dart:io';

import 'package:zephyr/database/app_database.dart';
import 'package:zephyr/database/db.dart';
import 'package:zephyr/database/repositories/comic_folder_repository.dart';
import 'package:zephyr/database/repositories/comic_follow_repository.dart';
import 'package:zephyr/database/repositories/download_task_repository.dart';
import 'package:zephyr/database/repositories/legacy_comic_repository.dart';
import 'package:zephyr/database/repositories/plugin_repository.dart';
import 'package:zephyr/database/repositories/reader_repository.dart';
import 'package:zephyr/database/repositories/search_bookmark_repository.dart';
import 'package:zephyr/database/repositories/unified_comic_repository.dart';
import 'package:zephyr/database/repositories/user_setting_repository.dart';
import 'package:zephyr/util/async/worker_pool.dart';
import 'package:zephyr/util/rust/rust_loader.dart';

/// 应用数据库门面：第一层 SQL 执行 + 各领域仓库。
class Database {
  final BreezeDatabase db;

  late final UserSettingRepository userSettings = UserSettingRepository(db);
  late final PluginRepository plugins = PluginRepository(db);
  late final UnifiedComicFavoriteRepository favorites =
      UnifiedComicFavoriteRepository(db);
  late final UnifiedComicHistoryRepository histories =
      UnifiedComicHistoryRepository(db);
  late final UnifiedComicDownloadRepository downloads =
      UnifiedComicDownloadRepository(db);
  late final ComicFolderRepository folders = ComicFolderRepository(db);
  late final ComicLinkRepository links = ComicLinkRepository(db);
  late final ComicFollowRepository follows = ComicFollowRepository(db);
  late final ComicReadPreferenceRepository readPreferences =
      ComicReadPreferenceRepository(db);
  late final ComicReadChapterRepository readChapters =
      ComicReadChapterRepository(db);
  late final SearchBookmarkRepository bookmarks = SearchBookmarkRepository(db);
  late final DownloadTaskRepository downloadTasks = DownloadTaskRepository(db);
  late final LegacyComicRepository legacy = LegacyComicRepository(db);

  Database._(this.db);

  /// 在 worker isolate 中基于已打开的 handle 构造数据库门面。
  factory Database.fromHandle(int handle) =>
      Database._(BreezeDatabase.fromHandle(handle));

  static Future<Database> open({
    required String path,
    required String legacyObjectBoxDir,
    bool archiveLegacyData = false,
  }) async {
    return Database._(
      await openAppDatabase(
        path: path,
        legacyObjectBoxDir: legacyObjectBoxDir,
        archiveLegacyData: archiveLegacyData,
      ),
    );
  }

  Future<String> queryJson(String sql, [List<Object?> params = const []]) =>
      db.queryJson(sql, params);

  Future<List<Map<String, dynamic>>> query(
    String sql, [
    List<Object?> params = const [],
  ]) => db.query(sql, params);

  Future<DbWriteResult> execute(
    String sql, [
    List<Object?> params = const [],
  ]) => db.execute(sql, params);

  Future<void> executeScript(String sql) => db.executeScript(sql);

  Future<DbTransaction> begin({bool write = true}) => db.begin(write: write);

  /// 显式事务。
  ///
  /// 事务运行在独立 SQLite 连接上（`BEGIN IMMEDIATE`），句柄放在当前 Zone：
  /// 回调内的 repository 调用和 `db.query/execute` 都会自动路由到事务连接，
  /// 多表操作可以安全地包在一个事务里；嵌套的 repository 事务会复用当前事务。
  Future<T> transaction<T>(
    Future<T> Function(DbTransaction tx) action, {
    bool write = true,
  }) => db.transaction(action, write: write);

  Stream<Set<String>> get changes => db.changes;

  /// 数据备份/启动快照使用的全库 JSON（键名与旧 ObjectBox 备份保持兼容）。
  Future<String> collectAllDataJson({bool removeIds = false}) {
    return transaction((_) async {
      Future<List<Map<String, dynamic>>> read<T>(
        Future<List<T>> future,
        Map<String, dynamic> Function(T value) toJson,
      ) async {
        final values = await future;
        return values.map((value) {
          final json = Map<String, dynamic>.from(toJson(value));
          if (removeIds) json.remove('id');
          return json;
        }).toList();
      }

      final data = <String, dynamic>{
        'bikaComicHistory': await read(
          legacy.listBikaHistories(),
          (e) => e.toJson(),
        ),
        'bikaComicDownload': await read(
          legacy.listBikaDownloads(),
          (e) => e.toJson(),
        ),
        'jmFavorite': await read(legacy.listJmFavorites(), (e) => e.toJson()),
        'jmHistory': await read(legacy.listJmHistories(), (e) => e.toJson()),
        'jmDownload': await read(legacy.listJmDownloads(), (e) => e.toJson()),
        'unifiedComicFavorite': await read(
          favorites.getAll(),
          (e) => e.toJson(),
        ),
        'unifiedComicHistory': await read(
          histories.getAll(),
          (e) => e.toJson(),
        ),
        'comicFollow': await read(follows.getAll(), (e) => e.toJson()),
        'unifiedComicDownload': await read(
          downloads.getAll(),
          (e) => e.toJson(),
        ),
        'userSetting': await () async {
          final user = await userSettings.get();
          if (user == null) return <Map<String, dynamic>>[];
          final json = Map<String, dynamic>.from(user.toJson());
          if (removeIds) json.remove('id');
          return <Map<String, dynamic>>[json];
        }(),
        'downloadTask': await read(downloadTasks.getAll(), (e) => e.toJson()),
        'pluginConfig': await read(plugins.listConfigs(), (e) => e.toJson()),
        'pluginInfo': await read(
          plugins.listInfosWithScripts(),
          (e) => e.toJson(),
        ),
        'comicFolder': await read(folders.getAll(), (e) => e.toJson()),
        'comicLink': await read(links.getAll(), (e) => e.toJson()),
        'comicReadPreference': await read(
          readPreferences.getAll(),
          (e) => e.toJson(),
        ),
        'comicReadChapter': await read(
          readChapters.getAll(),
          (e) => e.toJson(),
        ),
        'searchBookmark': await read(bookmarks.getAll(), (e) => e.toJson()),
      };
      return jsonEncode(data);
    }, write: false);
  }

  Future<void> writeAllDataJsonFileAsync(
    String path, {
    bool removeIds = false,
  }) {
    final handle = db.handle;
    return runInWorker(
      () => _writeAllDataJsonFile(handle, path, removeIds: removeIds),
    );
  }

  Future<void> close() => db.close();
}

/// 在 worker 池内读取全库 JSON 并落盘：全库序列化/编码不占 UI isolate。
Future<void> _writeAllDataJsonFile(
  int handle,
  String path, {
  required bool removeIds,
}) async {
  await initRustLib();
  final json = await Database.fromHandle(handle)
      .collectAllDataJson(removeIds: removeIds);
  await File(path).writeAsString(json);
}
