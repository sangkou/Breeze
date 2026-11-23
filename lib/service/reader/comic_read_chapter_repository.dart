import 'dart:async';

import 'package:zephyr/main.dart';
import 'package:zephyr/object_box/model.dart';

/// 已读章节仓库。
///
/// 详情页按 `source + comicId` 批量查询已读章节 id；阅读器打开章节时写入。
/// 写入后通过 [changes] 通知当前漫画的详情页刷新置灰状态。
class ComicReadChapterRepository {
  ComicReadChapterRepository._();

  static final ComicReadChapterRepository instance =
      ComicReadChapterRepository._();

  final _changes = StreamController<String>.broadcast();

  /// 变更流：事件为 `$source:$comicId`，订阅方自行过滤当前漫画。
  Stream<String> get changes => _changes.stream;

  /// 查询某本漫画已读章节 id 集合。
  Future<Set<String>> readChapterIds({
    required String source,
    required String comicId,
  }) async {
    final resolvedSource = source.trim();
    final resolvedComicId = comicId.trim();
    if (resolvedSource.isEmpty || resolvedComicId.isEmpty) {
      return const <String>{};
    }

    final rows = await database.readChapters.listByComic(
      source: resolvedSource,
      comicId: resolvedComicId,
    );
    return rows
        .map((item) => item.chapterId)
        .where((id) => id.isNotEmpty)
        .toSet();
  }

  /// 标记章节已读；同一章重复调用只刷新阅读时间。
  Future<void> markRead({
    required String source,
    required String comicId,
    required String chapterId,
    required String chapterTitle,
    required int chapterOrder,
  }) async {
    final resolvedSource = source.trim();
    final resolvedComicId = comicId.trim();
    final resolvedChapterId = chapterId.trim();
    if (resolvedSource.isEmpty ||
        resolvedComicId.isEmpty ||
        resolvedChapterId.isEmpty) {
      return;
    }

    final key = comicReadChapterUniqueKey(
      resolvedSource,
      resolvedComicId,
      resolvedChapterId,
    );
    final now = DateTime.now().toUtc();
    final existing = await database.readChapters.getByKey(key);
    final entity =
        existing ??
        ComicReadChapter(
          uniqueKey: key,
          source: resolvedSource,
          comicId: resolvedComicId,
          chapterId: resolvedChapterId,
          chapterTitle: chapterTitle.trim(),
          chapterOrder: chapterOrder,
          readAt: now,
          updatedAt: now,
        );
    entity
      ..chapterTitle = chapterTitle.trim()
      ..chapterOrder = chapterOrder
      ..readAt = now
      ..updatedAt = now;
    await database.readChapters.put(entity);

    _changes.add('$resolvedSource:$resolvedComicId');
  }
}
