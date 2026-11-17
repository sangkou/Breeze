import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:zephyr/main.dart';
import 'package:zephyr/object_box/model.dart';
import 'package:zephyr/object_box/objectbox.g.dart';
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
/// 用户的选择保存在 `<files>/folder_covers.json`（folderSyncId -> 漫画信息），
/// 不新增 ObjectBox 字段，避免改数据库模型与迁移。
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

  /// 文件夹卡片要显示的封面；null 表示没有可用封面。
  ComicSimplifyEntryInfo? coverFor(ComicFolder folder) {
    final override = _overrides[folder.syncId];
    if (override != null) return override;
    return _autoCover(folder);
  }

  ComicSimplifyEntryInfo? _autoCover(ComicFolder folder) {
    if (_autoCache.containsKey(folder.syncId)) {
      return _autoCache[folder.syncId];
    }
    final info = _firstComicInFolder(folder);
    _autoCache[folder.syncId] = info;
    return info;
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
  List<ComicSimplifyEntryInfo> comicsInFolder(ComicFolder folder) {
    final result = <ComicSimplifyEntryInfo>[];
    final query = _linksQuery(folder).build();
    try {
      for (final link in query.find()) {
        final info = _resolveEntry(link.comicUniqueKey, folder.type);
        if (info != null) result.add(info);
      }
    } finally {
      query.close();
    }
    return result;
  }

  ComicSimplifyEntryInfo? _firstComicInFolder(ComicFolder folder) {
    try {
      final query = _linksQuery(folder).build();
      try {
        final link = query.findFirst();
        if (link == null) return null;
        return _resolveEntry(link.comicUniqueKey, folder.type);
      } finally {
        query.close();
      }
    } catch (e) {
      logger.e(e);
      return null;
    }
  }

  Query<ComicLink> _linksQuery(ComicFolder folder) {
    return objectbox.comicLinkBox
        .query(
          ComicLink_.folderSyncId
              .equals(folder.syncId)
              .and(ComicLink_.typeData.equals(folder.typeData))
              .and(ComicLink_.deletedAt.isNull()),
        )
        .order(ComicLink_.createdAt, flags: Order.descending);
  }

  /// 把漫画唯一键解析成条目信息；与书架 bloc 里的解析保持同一套规则。
  ComicSimplifyEntryInfo? _resolveEntry(
    String uniqueKey,
    ComicFolderType type,
  ) {
    switch (type) {
      case ComicFolderType.favorite:
        final query = objectbox.unifiedFavoriteBox
            .query(
              UnifiedComicFavorite_.uniqueKey
                  .equals(uniqueKey)
                  .and(UnifiedComicFavorite_.deleted.equals(false)),
            )
            .build();
        try {
          final comic = query.findFirst();
          if (comic == null) return null;
          return unifiedComicFromUnifiedFavorite(comic).toSimplifyEntryInfo();
        } finally {
          query.close();
        }
      case ComicFolderType.download:
        final query = objectbox.unifiedDownloadBox
            .query(
              UnifiedComicDownload_.uniqueKey
                  .equals(uniqueKey)
                  .and(UnifiedComicDownload_.deleted.equals(false)),
            )
            .build();
        try {
          final comic = query.findFirst();
          if (comic == null) return null;
          return unifiedComicFromUnifiedDownload(comic).toSimplifyEntryInfo();
        } finally {
          query.close();
        }
      case ComicFolderType.history:
        final query = objectbox.unifiedHistoryBox
            .query(
              UnifiedComicHistory_.uniqueKey
                  .equals(uniqueKey)
                  .and(UnifiedComicHistory_.deleted.equals(false)),
            )
            .build();
        try {
          final comic = query.findFirst();
          if (comic == null) return null;
          return unifiedComicFromUnifiedHistory(comic).toSimplifyEntryInfo();
        } finally {
          query.close();
        }
    }
  }
}
