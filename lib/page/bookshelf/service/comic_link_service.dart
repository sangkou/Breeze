import 'dart:convert';

import 'package:zephyr/database/database.dart';
import 'package:zephyr/main.dart';
import 'package:zephyr/network/http/picture/picture.dart';
import 'package:zephyr/network/sync/sync_device_id.dart';
import 'package:zephyr/object_box/model.dart';

import 'package:zephyr/page/bookshelf/service/comic_folder_service.dart';

class ComicLinkService {
  static String get _deviceId => syncDeviceId;

  static Map<String, int> _parseVersionVector(String json) {
    if (json.trim().isEmpty) return <String, int>{};
    try {
      final map = jsonDecode(json) as Map<String, dynamic>;
      return map.map((k, v) => MapEntry(k, (v as num).toInt()));
    } catch (_) {
      return <String, int>{};
    }
  }

  static String _encodeVersionVector(Map<String, int> vector) {
    return jsonEncode(vector);
  }

  static String _bumpVersionVector(String json) {
    final vector = _parseVersionVector(json);
    vector[_deviceId] = (vector[_deviceId] ?? 0) + 1;
    return _encodeVersionVector(vector);
  }

  static int _now() {
    return DateTime.now().toUtc().millisecondsSinceEpoch;
  }

  static String _uniqueKey(
    String comicUniqueKey,
    String? folderSyncId,
    ComicFolderType type,
  ) {
    return '$comicUniqueKey|${folderSyncId ?? ''}|${type.name}';
  }

  static Future<String?> _folderSyncIdByPath(
    String? folderPath,
    ComicFolderType type, {
    Database? db,
  }) async {
    if (folderPath == null || folderPath.isEmpty) return null;
    return ComicFolderService.folderSyncIdByPath(folderPath, type, db: db);
  }

  /// 列出该类型下全部未删除的漫画链接，按 createdAt 排序（新的在前）
  static Future<List<ComicLink>> listAllLinks(
    ComicFolderType type, {
    bool sortAscending = false,
    Database? db,
  }) {
    return (db ?? database).links.listActiveByType(
      type.name,
      ascending: sortAscending,
    );
  }

  /// 列出某路径下未删除的漫画链接，按 createdAt 排序（新的在前）
  static Future<List<ComicLink>> listLinks(
    String? folderPath,
    ComicFolderType type, {
    bool sortAscending = false,
    Database? db,
  }) async {
    final folderSyncId = await _folderSyncIdByPath(folderPath, type, db: db);
    return (db ?? database).links.listActiveByFolder(
      folderSyncId,
      type.name,
      ascending: sortAscending,
    );
  }

  /// 获取漫画在某个类型下的所有链接（包括根目录）
  static Future<List<ComicLink>> linksOfComic(
    String comicUniqueKey,
    ComicFolderType type,
  ) {
    return database.links.listActiveByComic(comicUniqueKey, type.name);
  }

  /// 把漫画添加到指定路径
  static Future<ComicLink> addComic(
    String comicUniqueKey,
    String? folderPath,
    ComicFolderType type,
  ) async {
    final folderSyncId = await _folderSyncIdByPath(folderPath, type);
    final uniqueKey = _uniqueKey(comicUniqueKey, folderSyncId, type);
    final existing = await database.links.getByUniqueKey(uniqueKey);

    final now = _now();
    if (existing != null) {
      if (existing.deletedAt != null) {
        //  Tombstone 复活
        existing
          ..deletedAt = null
          ..createdAt = now
          ..updatedAt = now
          ..versionVectorJson = _bumpVersionVector(existing.versionVectorJson);
        if (existing.folderSyncId == null && folderSyncId != null) {
          existing.folderSyncId = folderSyncId;
        }
        await database.links.put(existing);
        return existing;
      }
      return existing;
    }

    final link = ComicLink(
      uniqueKey: uniqueKey,
      comicUniqueKey: comicUniqueKey,
      folderSyncId: folderSyncId,
      typeData: type.name,
      versionVectorJson: _encodeVersionVector({_deviceId: 1}),
      createdAt: now,
      updatedAt: now,
    );
    await database.links.put(link);
    return link;
  }

  /// 从指定路径移除漫画。
  /// 对收藏类型为软删除；对下载类型为真实删除（下载无同步逻辑）。
  /// 收藏类型下若这是最后一个链接，会同步把漫画本身标记为删除。
  /// 下载类型下若这是最后一个链接，会同步删除下载记录及对应文件。
  static Future<void> removeComic(
    String comicUniqueKey,
    String? folderPath,
    ComicFolderType type,
  ) async {
    // 允许在文件夹已经被软删除后，仍然能清理指向它的链接。
    final folderSyncId = await ComicFolderService.folderSyncIdByPath(
      folderPath,
      type,
      includeDeleted: true,
    );
    await _removeComicBySyncId(comicUniqueKey, folderSyncId, type);
  }

  static Future<void> _removeComicBySyncId(
    String comicUniqueKey,
    String? folderSyncId,
    ComicFolderType type,
  ) async {
    final uniqueKey = _uniqueKey(comicUniqueKey, folderSyncId, type);
    final link = await database.links.getByUniqueKey(uniqueKey);
    if (link == null || link.deletedAt != null) return;

    if (type == ComicFolderType.download) {
      await database.links.removeById(link.id);
    } else {
      link
        ..deletedAt = _now()
        ..updatedAt = _now()
        ..versionVectorJson = _bumpVersionVector(link.versionVectorJson);
      await database.links.put(link);
    }

    if (type == ComicFolderType.favorite) {
      await _markFavoriteDeletedIfNoLinks(comicUniqueKey);
    } else if (type == ComicFolderType.download) {
      await _deleteDownloadIfNoLinks(comicUniqueKey);
    }
  }

  /// 把漫画从所有路径移除。
  /// 对收藏类型会标记漫画本身为删除；对下载类型会删除下载记录及文件。
  static Future<void> removeComicFromAll(
    String comicUniqueKey,
    ComicFolderType type,
  ) async {
    final links = await linksOfComic(comicUniqueKey, type);
    for (final link in links) {
      await _removeComicBySyncId(link.comicUniqueKey, link.folderSyncId, type);
    }

    // 兜底：即使没有 active 链接，也确保漫画本体状态一致。
    if (type == ComicFolderType.favorite) {
      await _markFavoriteDeletedIfNoLinks(comicUniqueKey);
    } else if (type == ComicFolderType.download) {
      await _deleteDownloadIfNoLinks(comicUniqueKey);
    }
  }

  static Future<void> _markFavoriteDeletedIfNoLinks(
    String comicUniqueKey,
  ) async {
    final remaining = await linksOfComic(
      comicUniqueKey,
      ComicFolderType.favorite,
    );
    if (remaining.isEmpty) {
      await _markFavoriteDeleted(comicUniqueKey);
    }
  }

  static Future<void> _markFavoriteDeleted(String comicUniqueKey) async {
    await database.favorites.markDeletedByKey(comicUniqueKey);
  }

  /// 移动漫画从一个路径到另一个路径
  static Future<void> moveComic(
    String comicUniqueKey,
    String? fromPath,
    String? toPath,
    ComicFolderType type,
  ) async {
    if ((fromPath ?? kComicFolderRootPath) ==
        (toPath ?? kComicFolderRootPath)) {
      return;
    }
    // 先添加目标链接，再移除原链接，避免中间态被判定为“最后一个链接”
    // 而导致对应的收藏记录被误标为删除。
    await addComic(comicUniqueKey, toPath, type);
    await removeComic(comicUniqueKey, fromPath, type);
  }

  // ==================== 批量操作 ====================

  /// 批量移动漫画到目标路径。目标位置已存在则跳过。
  static Future<void> batchMoveComics(
    Set<String> comicUniqueKeys,
    String? fromPath,
    String targetPath,
    ComicFolderType type,
  ) async {
    final toPath = targetPath.isEmpty ? null : targetPath;
    for (final key in comicUniqueKeys) {
      await moveComic(key, fromPath, toPath, type);
    }
  }

  /// 批量复制漫画到目标路径。目标位置已存在则跳过。
  static Future<void> batchCopyComics(
    Set<String> comicUniqueKeys,
    String targetPath,
    ComicFolderType type,
  ) async {
    final toPath = targetPath.isEmpty ? null : targetPath;
    for (final key in comicUniqueKeys) {
      await addComic(key, toPath, type);
    }
  }

  /// 批量从当前路径移除漫画。
  /// 对收藏类型，如果这是漫画的最后一条链接，会同步取消收藏。
  /// 对下载类型，如果这是漫画的最后一条链接，会同步删除下载记录及对应文件。
  static Future<void> batchRemoveComics(
    Set<String> comicUniqueKeys,
    String? folderPath,
    ComicFolderType type,
  ) async {
    for (final key in comicUniqueKeys) {
      await removeComic(key, folderPath, type);
    }
  }

  /// 移除某个文件夹及其子文件夹下的所有漫画链接。
  /// 对下载类型，当某漫画没有任何有效链接时会删除下载记录及文件。
  static Future<void> removeLinksInFolderTree(
    String folderPath,
    ComicFolderType type,
  ) async {
    // 文件夹可能已经被软删除（例如 FolderShelfBloc 先调 deleteFolder 再调本方法），
    // 因此需要查找包含已删除 folder 在内的记录来获取 syncId。
    final folderSyncId = await ComicFolderService.folderSyncIdByPath(
      folderPath,
      type,
      includeDeleted: true,
    );
    if (folderSyncId == null) return;

    final subtreeSyncIds = await _collectSubtreeSyncIds(folderSyncId, type);

    // 直接加载该类型下所有 active link 在内存里过滤，避免 oneOf 兼容性风险。
    final links = await database.links.listActiveByType(type.name);
    for (final link in links) {
      if (link.folderSyncId != null &&
          subtreeSyncIds.contains(link.folderSyncId)) {
        await _removeComicBySyncId(
          link.comicUniqueKey,
          link.folderSyncId,
          type,
        );
      }
    }
  }

  static Future<Set<String>> _collectSubtreeSyncIds(
    String rootSyncId,
    ComicFolderType type,
  ) async {
    // 文件夹可能已经被 deleteFolder 软删除，因此需要包含已删除的子孙文件夹，
    // 确保它们下面的链接也能被一并清理。
    final result = <String>{rootSyncId};
    final queue = [rootSyncId];
    while (queue.isNotEmpty) {
      final parentId = queue.removeLast();
      final children = await database.folders.listChildren(parentId, type.name);
      for (final child in children) {
        if (result.add(child.syncId)) queue.add(child.syncId);
      }
    }
    return result;
  }

  static Future<void> _deleteDownloadIfNoLinks(String comicUniqueKey) async {
    final remaining = await linksOfComic(
      comicUniqueKey,
      ComicFolderType.download,
    );
    if (remaining.isNotEmpty) return;

    final comic = await database.downloads.getByKey(comicUniqueKey);
    if (comic == null) return;

    // 先移除数据库记录，让调用方立即看到下载项已删除；磁盘清理
    // 继续在下面执行，失败也不会让孤立的历史记录阻塞后续重建。
    await database.downloads.removeById(comic.id);

    try {
      await deleteComicDownloadDirectory(
        comic.source,
        comic.comicId,
        legacyStorageRoot: comic.storageRoot,
      );
    } catch (e, stackTrace) {
      logger.e(
        'Failed to delete download files: ${comic.storageRoot}',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }
}
