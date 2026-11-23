import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zephyr/database/database.dart';
import 'package:zephyr/main.dart';
import 'package:zephyr/network/sync/sync_device_id.dart';
import 'package:zephyr/object_box/model.dart';

/// 测试辅助类：在独立临时目录创建 SQLite 数据库并设置全局 [database]。
class TestDatabaseHelper {
  static Directory? _tempDir;
  static Database? _database;

  static String get tempPath => _tempDir!.path;

  static Future<void> setUpTestDatabase() async {
    _tempDir = await Directory.systemTemp.createTemp('breeze_test_');
    _database = await Database.open(
      path: p.join(_tempDir!.path, 'breeze.sqlite3'),
      legacyObjectBoxDir: p.join(_tempDir!.path, 'missing_objectbox'),
    );
    database = _database!;
    await database.userSettings.put(UserSetting());
    syncDeviceId = 'test_device';
  }

  static Future<void> tearDownTestDatabase() async {
    await _database?.close();
    _database = null;
    if (_tempDir != null && await _tempDir!.exists()) {
      await _tempDir!.delete(recursive: true);
    }
    _tempDir = null;
  }

  static Future<void> cleanComicFolderBoxes() async {
    await database.folders.removeAll();
    await database.links.removeAll();
    await database.favorites.removeAll();
    await database.histories.removeAll();
    await database.downloads.removeAll();
    await database.readChapters.removeAll();
  }
}

/// 构造一个测试用的 UnifiedComicFavorite。
UnifiedComicFavorite createTestFavorite(
  String uniqueKey, {
  bool deleted = false,
  String source = 'test',
  DateTime? updatedAt,
}) {
  final now = updatedAt ?? DateTime.now().toUtc();
  return UnifiedComicFavorite(
    uniqueKey: uniqueKey,
    source: source,
    comicId: uniqueKey,
    title: 'Test Comic $uniqueKey',
    description: '',
    cover: '',
    creator: '',
    titleMeta: '',
    metadata: '',
    createdAt: now,
    updatedAt: now,
    deleted: deleted,
    schemaVersion: 1,
  );
}

/// 构造一个测试用的 UnifiedComicHistory。
UnifiedComicHistory createTestHistory(
  String uniqueKey, {
  bool deleted = false,
  DateTime? updatedAt,
}) {
  final now = updatedAt ?? DateTime.now().toUtc();
  return UnifiedComicHistory(
    uniqueKey: uniqueKey,
    source: 'test',
    comicId: uniqueKey,
    title: 'Test Comic $uniqueKey',
    description: '',
    cover: '',
    creator: '',
    titleMeta: '',
    metadata: '',
    chapterId: '',
    chapterTitle: '',
    chapterOrder: 0,
    pageIndex: 0,
    createdAt: now,
    lastReadAt: now,
    updatedAt: now,
    deleted: deleted,
    schemaVersion: 1,
  );
}

/// 构造一个测试用的 UnifiedComicDownload。
UnifiedComicDownload createTestDownload(
  String uniqueKey, {
  String storageRoot = '',
  bool deleted = false,
  DateTime? updatedAt,
}) {
  final now = updatedAt ?? DateTime.now().toUtc();
  return UnifiedComicDownload(
    uniqueKey: uniqueKey,
    source: 'test',
    comicId: uniqueKey,
    title: 'Test Comic $uniqueKey',
    description: '',
    cover: '',
    creator: '',
    titleMeta: '',
    metadata: '',
    totalViews: 0,
    totalLikes: 0,
    totalComments: 0,
    isFavourite: false,
    isLiked: false,
    allowComment: false,
    allowLike: false,
    allowFavorite: false,
    allowDownload: false,
    chapters: '',
    detailJson: '',
    storageRoot: storageRoot,
    createdAt: now,
    updatedAt: now,
    downloadedAt: now,
    deleted: deleted,
    schemaVersion: 1,
  );
}
