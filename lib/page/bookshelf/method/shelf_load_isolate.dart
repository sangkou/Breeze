import 'package:zephyr/database/database.dart';
import 'package:zephyr/object_box/model.dart';
import 'package:zephyr/page/bookshelf/method/comic_search_text.dart';
import 'package:zephyr/page/bookshelf/models/shelf_page_mode.dart';
import 'package:zephyr/page/bookshelf/service/comic_folder_service.dart';
import 'package:zephyr/util/rust/rust_loader.dart';
import 'package:zephyr/widgets/comic_entry/models/models.dart';
import 'package:zephyr/widgets/comic_simplify_entry/comic_simplify_entry_info.dart';

/// 书架分页大小：收藏/历史 2000，下载数据量大用 200。
int shelfPageSize(ShelfPageMode mode) =>
    mode == ShelfPageMode.download ? 200 : 2000;

/// 单页结果为空但仍有更多数据时，最多连续翻几页再返回（搜索/失效链接场景）。
const int _maxSparsePages = 5;

/// 书架加载任务：只携带可跨 isolate 传递的简单参数。
class ShelfLoadTask {
  const ShelfLoadTask({
    required this.handle,
    required this.mode,
    required this.currentPath,
    required this.keyword,
    required this.sort,
    required this.sources,
    this.offset = 0,
    this.limit = 2000,
  });

  final int handle;
  final String mode;
  final String currentPath;
  final String keyword;
  final String sort;
  final List<String> sources;

  /// 主列表（链接/历史）的起始行偏移。
  final int offset;

  /// 本次最多取多少行原始记录。
  final int limit;
}

/// 书架加载结果：全部为普通 Dart 对象，可由 `compute` 零拷贝交回 UI。
class ShelfLoadResult {
  const ShelfLoadResult({
    required this.folders,
    required this.folderComicCounts,
    required this.comics,
    required this.searchTexts,
    required this.nextOffset,
    required this.hasMore,
  });

  final List<ComicFolder> folders;
  final Map<String, int> folderComicCounts;
  final List<ComicSimplifyEntryInfo> comics;
  final Map<String, String> searchTexts;

  /// 下一页应使用的偏移（已包含第一页的空页补偿）。
  final int nextOffset;

  /// 是否还有更多原始行可加载。
  final bool hasMore;
}

/// 在 compute isolate 内完成书架（收藏/历史/下载）的查询、解码与映射。
///
/// 分页按原始行（ComicLink / UnifiedComicHistory）计数；单页解不出漫画时
/// （链接失效、搜索不匹配）会在同一个 isolate 内最多续翻 5 页。
///
/// 注意：不能引用 UI 全局状态（`database`、`globalSetting`、`BuildContext`）；
/// RustLib 需要在本 isolate 内初始化。
Future<ShelfLoadResult> loadShelfInIsolate(ShelfLoadTask task) async {
  await initRustLib();
  final db = Database.fromHandle(task.handle);
  final mode = ShelfPageMode.values.byName(task.mode);
  final folderType = comicFolderTypeOf(mode);
  final keyword = task.keyword;
  final sort = task.sort;
  final sortAscending = sort == 'da';
  final sourceFilter = _sourceFilter(task.sources);
  final isSearching = keyword.trim().isNotEmpty;
  final normalizedKeyword = isSearching ? normalizeSearchText(keyword) : '';

  // 历史无文件夹体系：直读历史表分页。
  if (mode == ShelfPageMode.history) {
    return _loadHistoryShelf(
      db,
      sortAscending: sortAscending,
      keyword: keyword,
      sourceFilter: sourceFilter,
      offset: task.offset,
      pageSize: task.limit,
    );
  }

  // 文件夹与计数只在第一页计算；搜索时不展示文件夹。
  final isFirstPage = task.offset == 0;
  final folders = isFirstPage && !isSearching
      ? await ComicFolderService.listChildFolders(
          task.currentPath,
          folderType,
          sortAscending: sortAscending,
          db: db,
        )
      : const <ComicFolder>[];
  var folderComicCounts = const <String, int>{};
  if (isFirstPage && !isSearching) {
    final byFolder = await db.links.countActiveByFolder(
      folderType.name,
      sources: task.sources,
    );
    folderComicCounts = <String, int>{
      for (final folder in folders)
        if ((byFolder[folder.syncId] ?? 0) > 0)
          (task.currentPath.isEmpty
                  ? '/${folder.name}'
                  : '${task.currentPath}/${folder.name}'):
              byFolder[folder.syncId]!,
    };
  }

  // ComicLink.folderSyncId 存的是文件夹 syncId，而 currentPath 是显示路径，
  // 进入子文件夹时必须先解析，否则一条链接都匹配不到。
  final folderSyncId = !isSearching && task.currentPath.isNotEmpty
      ? await ComicFolderService.folderSyncIdByPath(
          task.currentPath,
          folderType,
          db: db,
        )
      : null;

  final comics = <ComicSimplifyEntryInfo>[];
  final searchTexts = <String, String>{};
  final seenKeys = <String>{};
  var cursor = task.offset;
  var hasMore = false;
  for (var attempted = 0; attempted < _maxSparsePages; attempted++) {
    final rows = await db.links.listShelfLinks(
      typeData: folderType.name,
      folderSyncId: folderSyncId,
      allFolders: isSearching,
      sort: sort,
      offset: cursor,
      limit: task.limit + 1,
    );
    hasMore = rows.length > task.limit;
    final pageLinks = hasMore ? rows.sublist(0, task.limit) : rows;
    cursor += pageLinks.length;
    if (pageLinks.isEmpty) break;
    await _appendResolvedComics(
      folderType: folderType,
      links: pageLinks,
      db: db,
      sourceFilter: sourceFilter,
      normalizedKeyword: normalizedKeyword,
      comics: comics,
      searchTexts: searchTexts,
      seenKeys: seenKeys,
    );
    if (comics.isNotEmpty || !hasMore) break;
  }

  return ShelfLoadResult(
    folders: folders,
    folderComicCounts: folderComicCounts,
    comics: comics,
    searchTexts: searchTexts,
    nextOffset: cursor,
    hasMore: hasMore,
  );
}

Future<ShelfLoadResult> _loadHistoryShelf(
  Database db, {
  required bool sortAscending,
  required String keyword,
  required Set<String>? sourceFilter,
  required int offset,
  required int pageSize,
}) async {
  final isSearching = keyword.trim().isNotEmpty;
  final normalizedKeyword = isSearching ? normalizeSearchText(keyword) : '';
  final comics = <ComicSimplifyEntryInfo>[];
  final searchTexts = <String, String>{};
  final filterSources = sourceFilter != null && sourceFilter.isNotEmpty;
  var cursor = offset;
  var hasMore = false;
  for (var attempted = 0; attempted < _maxSparsePages; attempted++) {
    final rows = await db.histories.listActive(
      ascending: sortAscending,
      limit: pageSize + 1,
      offset: cursor,
    );
    hasMore = rows.length > pageSize;
    final pageRows = hasMore ? rows.sublist(0, pageSize) : rows;
    cursor += pageRows.length;
    if (pageRows.isEmpty) break;
    for (final history in pageRows) {
      if (filterSources && !sourceFilter.contains(history.source)) continue;
      final info = unifiedComicFromUnifiedHistory(history)
          .toSimplifyEntryInfo();
      final key = '${info.from.trim()}:${info.id}';
      final searchText = buildComicSearchText(history);
      if (isSearching && !searchText.contains(normalizedKeyword)) {
        continue;
      }
      comics.add(info);
      searchTexts[key] = searchText;
    }
    if (comics.isNotEmpty || !hasMore) break;
  }
  return ShelfLoadResult(
    folders: const <ComicFolder>[],
    folderComicCounts: const <String, int>{},
    comics: comics,
    searchTexts: searchTexts,
    nextOffset: cursor,
    hasMore: hasMore,
  );
}

/// 解析一页链接并把命中的漫画追加到结果（去重、来源过滤、关键字过滤）。
Future<void> _appendResolvedComics({
  required ComicFolderType folderType,
  required List<ComicLink> links,
  required Database db,
  required Set<String>? sourceFilter,
  required String normalizedKeyword,
  required List<ComicSimplifyEntryInfo> comics,
  required Map<String, String> searchTexts,
  required Set<String> seenKeys,
}) async {
  final resolvedByKey = await _resolveComics(
    folderType,
    {for (final link in links) link.comicUniqueKey}.toList(),
    db,
  );
  for (final link in links) {
    final resolved = resolvedByKey[link.comicUniqueKey];
    if (resolved == null) continue;
    if (sourceFilter != null && !sourceFilter.contains(resolved.info.source)) {
      continue;
    }
    final key = '${resolved.info.from.trim()}:${resolved.info.id}';
    if (!seenKeys.add(key)) continue;
    if (normalizedKeyword.isNotEmpty &&
        !resolved.searchText.contains(normalizedKeyword)) {
      continue;
    }
    comics.add(resolved.info);
    searchTexts[key] = resolved.searchText;
  }
}

typedef _ResolvedComic = ({ComicSimplifyEntryInfo info, String searchText});

/// 批量把 `ComicLink.comicUniqueKey` 解析成列表项与搜索文本。
///
/// 逐条 `getByKey` 会形成 N+1 查询（300 条链接实测约 88ms），这里按类型
/// 批量 `WHERE "uniqueKey" IN (...)` 预取，只对命中的行做映射与搜索文本。
Future<Map<String, _ResolvedComic>> _resolveComics(
  ComicFolderType folderType,
  List<String> uniqueKeys,
  Database db,
) async {
  final resolved = <String, _ResolvedComic>{};
  switch (folderType) {
    case ComicFolderType.favorite:
      for (final comic in await db.favorites.getByKeys(uniqueKeys)) {
        if (comic.deleted) continue;
        resolved[comic.uniqueKey] = (
          info: unifiedComicFromUnifiedFavorite(comic).toSimplifyEntryInfo(),
          searchText: buildComicSearchText(comic),
        );
      }
    case ComicFolderType.download:
      // 书架不返回章节明细：查询不取 chapters/detailJson，映射也不带 raw。
      for (final comic in await db.downloads.getShelfByKeys(uniqueKeys)) {
        if (comic.deleted) continue;
        resolved[comic.uniqueKey] = (
          info: unifiedComicFromUnifiedDownload(
            comic,
            includeRaw: false,
          ).toSimplifyEntryInfo(),
          searchText: buildComicSearchText(comic),
        );
      }
    case ComicFolderType.history:
      for (final comic in await db.histories.getByKeys(uniqueKeys)) {
        if (comic.deleted) continue;
        resolved[comic.uniqueKey] = (
          info: unifiedComicFromUnifiedHistory(comic).toSimplifyEntryInfo(),
          searchText: buildComicSearchText(comic),
        );
      }
  }
  return resolved;
}

Set<String>? _sourceFilter(List<String> sources) {
  final cleaned = sources
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toSet();
  return cleaned.isEmpty ? null : cleaned;
}
