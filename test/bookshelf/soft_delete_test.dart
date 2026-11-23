import 'package:flutter_test/flutter_test.dart';
import 'package:zephyr/main.dart';

import '../test_helper.dart';

void main() {
  setUpAll(TestDatabaseHelper.setUpTestDatabase);
  tearDownAll(TestDatabaseHelper.tearDownTestDatabase);
  tearDown(TestDatabaseHelper.cleanComicFolderBoxes);

  final base = DateTime.utc(2026, 1, 1, 12);

  test('收藏墓碑只保留必要字段且重复删除不再改动', () async {
    final favorite = createTestFavorite('test:fav', updatedAt: base)
      ..description = 'description'
      ..cover = 'cover-path'
      ..creator = '[{"name":"author"}]'
      ..titleMeta = '[{"name":"title"}]'
      ..metadata = '[{"name":"tag"}]';
    await database.favorites.put(favorite);
    final before = DateTime.now().toUtc().millisecondsSinceEpoch;

    expect(await database.favorites.markDeletedByKey(favorite.uniqueKey), 1);

    final row = await database.favorites.getByKey(favorite.uniqueKey);
    expect(row, isNotNull);
    expect(row!.deleted, isTrue);
    expect(row.updatedAt.millisecondsSinceEpoch, greaterThanOrEqualTo(before));
    expect(row.title, favorite.title);
    expect(row.source, favorite.source);
    expect(row.comicId, favorite.comicId);
    expect(row.description, isEmpty);
    expect(row.cover, isEmpty);
    expect(row.creator, isEmpty);
    expect(row.titleMeta, isEmpty);
    expect(row.metadata, isEmpty);

    final firstUpdatedAt = row.updatedAt;
    expect(await database.favorites.markDeletedByKey(favorite.uniqueKey), 0);
    final unchanged = await database.favorites.getByKey(favorite.uniqueKey);
    expect(unchanged!.updatedAt, firstUpdatedAt);
  });

  test('收藏批量墓碑生效并返回影响行数', () async {
    final first = createTestFavorite('test:fav-a', updatedAt: base);
    final second = createTestFavorite('test:fav-b', updatedAt: base);
    await database.favorites.putMany([first, second]);
    final before = DateTime.now().toUtc().millisecondsSinceEpoch;

    final changed = await database.favorites.markDeletedByKeys([
      first.uniqueKey,
      second.uniqueKey,
      'test:missing',
    ]);
    expect(changed, 2);

    for (final key in [first.uniqueKey, second.uniqueKey]) {
      final row = await database.favorites.getByKey(key);
      expect(row!.deleted, isTrue);
      expect(
        row.updatedAt.millisecondsSinceEpoch,
        greaterThanOrEqualTo(before),
      );
    }
  });

  test('批量历史墓碑精简展示字段、保留章节定位并跳过已删除记录', () async {
    final first = createTestHistory('test:h1', updatedAt: base)
      ..description = 'description'
      ..cover = 'cover-path'
      ..creator = '[{"name":"author"}]'
      ..titleMeta = '[{"name":"title"}]'
      ..metadata = '[{"name":"tag"}]'
      ..chapterId = 'ep-1'
      ..chapterOrder = 3;
    final second = createTestHistory('test:h2', updatedAt: base);
    final already = createTestHistory(
      'test:h3',
      deleted: true,
      updatedAt: base,
    );
    await database.histories.putMany([first, second, already]);
    final before = DateTime.now().toUtc().millisecondsSinceEpoch;

    final changed = await database.histories.markDeletedByKeys([
      first.uniqueKey,
      second.uniqueKey,
      already.uniqueKey,
      'test:missing',
    ]);
    expect(changed, 2);

    final row = await database.histories.getByKey(first.uniqueKey);
    expect(row!.deleted, isTrue);
    expect(row.updatedAt.millisecondsSinceEpoch, greaterThanOrEqualTo(before));
    expect(row.lastReadAt, row.updatedAt);
    expect(row.chapterId, 'ep-1');
    expect(row.chapterOrder, 3);
    expect(row.description, isEmpty);
    expect(row.cover, isEmpty);
    expect(row.creator, isEmpty);
    expect(row.titleMeta, isEmpty);
    expect(row.metadata, isEmpty);

    final untouched = await database.histories.getByKey(already.uniqueKey);
    expect(untouched!.updatedAt, base);
    expect(untouched.lastReadAt, base);
  });

  test('单条删除历史同样刷新 updatedAt 与 lastReadAt', () async {
    final history = createTestHistory('test:h4', updatedAt: base);
    await database.histories.put(history);
    final before = DateTime.now().toUtc().millisecondsSinceEpoch;

    expect(await database.histories.markDeletedByKey(history.uniqueKey), 1);

    final row = await database.histories.getByKey(history.uniqueKey);
    expect(row!.updatedAt.millisecondsSinceEpoch, greaterThanOrEqualTo(before));
    expect(row.lastReadAt, row.updatedAt);
  });
}
