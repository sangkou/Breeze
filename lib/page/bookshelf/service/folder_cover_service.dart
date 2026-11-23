import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:zephyr/database/database.dart';
import 'package:zephyr/main.dart';
import 'package:zephyr/object_box/model.dart';
import 'package:zephyr/util/get_path.dart';
import 'package:zephyr/widgets/comic_entry/models/models.dart';
import 'package:zephyr/widgets/comic_simplify_entry/comic_simplify_entry_info.dart';

/// 文件夹封面。
///
/// 规则：
/// 1. 用户指定过封面 → 用指定那本的封面；
/// 2. 否则取文件夹里最新加入的一本漫画；
/// 3. 文件夹为空 → 返回 null，由调用方回退到文件夹图标。
///
/// 用户的选择保存在 `<files>/folder_covers.json`（folderSyncId -> 漫画信息）。
/// 数据库查询是异步的，所以 [coverFor] 只读内存缓存；页面加载完成后调用
/// [ensureCovers] 批量补齐，再刷新一次卡片。
class FolderCoverService {
  FolderCoverService._();

  static final FolderCoverService instance = FolderCoverService._();

  static const String _fileName = 'folder_covers.json';

  final Map<String, ComicSimplifyEntryInfo> _overrides = {};
  final Map<String, ComicSimplifyEntryInfo?> _autoCache = {};
  Future<void>? _loading;
  bool _loaded = false;

  bool get isLoaded => _loaded;

  /// 读取本地覆盖记录，只会真正读一次；页面初始化时调用。
  Future<void> ensureLoaded() {
    if (_loaded) return Future<void>.value();
    return _loading ??= _load();
  }

  Future<void> _load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return;
      for (final entry in decoded.entries) {
        final syncId = entry.key;
        final value = entry.value;
        if (syncId is! String || value is! Map) continue;
        try {
          _overrides[syncId] = ComicSimplifyEntryInfo.fromJson(
            Map<String, dynamic>.from(value),
          );
        } catch (e) {
          // 单条记录损坏不影响其他文件夹。
          logger.w(e);
        }
      }
    } catch (e) {
      logger.e(e);
    } finally {
      _loaded = true;
      _loading = null;
    }
  }

  Future<File> _file() async {
    final dir = await getFilePath();
    return File(p.join(dir, _fileName));
  }

  ComicSimplifyEntryInfo? overrideFor(String folderSyncId) =>
      _overrides[folderSyncId];

  bool hasOverride(String folderSyncId) => _overrides.containsKey(folderSyncId);

  /// 文件夹卡片要显示的封面；只在内存里取，未命中返回 null（回退图标）。
  ComicSimplifyEntryInfo? coverFor(ComicFolder folder) {
    final override = _overrides[folder.syncId];
    if (override != null) return override;
    return _autoCache[folder.syncId];
  }

  /// 批量补齐自动封面，返回是否有新增。页面在每次加载完成后调用。
  Future<bool> ensureCovers(Iterable<ComicFolder> folders) async {
    var changed = false;
    for (final folder in folders) {
      if (_overrides.containsKey(folder.syncId)) continue;
      if (_autoCache.containsKey(folder.syncId)) continue;
      _autoCache[folder.syncId] = await _firstComicInFolder(folder);
      changed = true;
    }
    return changed;
  }

  /// 书架重新加载时清掉自动封面缓存，避免新增/移动漫画后仍是旧封面。
  void clearAutoCache() {
    _autoCache.clear();
  }

  /// 设置封面。[info] 为 null 表示恢复「自动」。
  Future<void> setOverride(
    String folderSyncId,
    ComicSimplifyEntryInfo? info,
  ) async {
    if (info == null) {
      _overrides.remove(folderSyncId);
    } else {
      _overrides[folderSyncId] = info;
    }
    _autoCache.remove(folderSyncId);
    await _save();
  }

  Future<void> _save() async {
    try {
      final file = await _file();
      final payload = <String, dynamic>{
        for (final entry in _overrides.entries)
          entry.key: entry.value.toJson(),
      };
      await file.writeAsString(jsonEncode(payload));
    } catch (e) {
      logger.e(e);
    }
  }

  /// 文件夹里的漫画（按加入时间倒序），供封面选择弹窗使用。
  Future<List<ComicSimplifyEntryInfo>> comicsInFolder(
    ComicFolder folder,
  ) async {
    final result = <ComicSimplifyEntryInfo>[];
    final links = await database.links.listActiveByFolder(
      folder.syncId,
      folder.typeData,
    );
    for (final link in links) {
      final info = await _resolveEntry(link.comicUniqueKey, folder.type);
      if (info != null) result.add(info);
    }
    return result;
  }

  Future<ComicSimplifyEntryInfo?> _firstComicInFolder(
    ComicFolder folder,
  ) async {
    try {
      final links = await database.links.listActiveByFolder(
        folder.syncId,
        folder.typeData,
      );
      if (links.isEmpty) return null;
      return _resolveEntry(links.first.comicUniqueKey, folder.type);
    } catch (e) {
      logger.e(e);
      return null;
    }
  }

  /// 把漫画唯一键解析成条目信息；与书架加载任务里的解析保持同一套规则。
  Future<ComicSimplifyEntryInfo?> _resolveEntry(
    String uniqueKey,
    ComicFolderType type,
  ) async {
    switch (type) {
      case ComicFolderType.favorite:
        for (final comic in await database.favorites.getByKeys([uniqueKey])) {
          if (comic.deleted) continue;
          return unifiedComicFromUnifiedFavorite(comic).toSimplifyEntryInfo();
        }
        return null;
      case ComicFolderType.download:
        for (final comic in await database.downloads.getShelfByKeys([
          uniqueKey,
        ])) {
          if (comic.deleted) continue;
          return unifiedComicFromUnifiedDownload(
            comic,
            includeRaw: false,
          ).toSimplifyEntryInfo();
        }
        return null;
      case ComicFolderType.history:
        for (final comic in await database.histories.getByKeys([uniqueKey])) {
          if (comic.deleted) continue;
          return unifiedComicFromUnifiedHistory(comic).toSimplifyEntryInfo();
        }
        return null;
    }
  }
}
