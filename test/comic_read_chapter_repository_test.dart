import 'package:flutter_test/flutter_test.dart';
import 'package:zephyr/main.dart';
import 'package:zephyr/object_box/model.dart';
import 'package:zephyr/page/comic_info/json/normal/normal_comic_all_info.dart';
import 'package:zephyr/page/comic_read/model/normal_comic_ep_info.dart';
import 'package:zephyr/service/reader/comic_read_chapter_repository.dart';
import 'package:zephyr/service/reader/reader_history_service.dart';

import 'test_helper.dart';

Future<void> _seedReadChapters() async {
  final repo = ComicReadChapterRepository.instance;
  await repo.markRead(
    source: 'src',
    comicId: 'c1',
    chapterId: 'ch1',
    chapterTitle: '第 1 话',
    chapterOrder: 1,
  );
  await repo.markRead(
    source: 'src',
    comicId: 'c1',
    chapterId: 'ch2',
    chapterTitle: '第 2 话',
    chapterOrder: 2,
  );
  await repo.markRead(
    source: 'src',
    comicId: 'c2',
    chapterId: 'ch1',
    chapterTitle: '另一本第 1 话',
    chapterOrder: 1,
  );
}

void main() {
  setUpAll(TestDatabaseHelper.setUpTestDatabase);
  tearDownAll(TestDatabaseHelper.tearDownTestDatabase);
  tearDown(TestDatabaseHelper.cleanComicFolderBoxes);

  test('按漫画隔离查询，重复标记同一章不新增记录', () async {
    final repo = ComicReadChapterRepository.instance;

    await _seedReadChapters();

    expect(await repo.readChapterIds(source: 'src', comicId: 'c1'), {
      'ch1',
      'ch2',
    });
    expect(await repo.readChapterIds(source: 'src', comicId: 'c2'), {'ch1'});
    expect(await repo.readChapterIds(source: 'other', comicId: 'c1'), isEmpty);
    expect(await database.readChapters.count(), 3);

    await repo.markRead(
      source: 'src',
      comicId: 'c1',
      chapterId: 'ch1',
      chapterTitle: '第 1 话（重读）',
      chapterOrder: 1,
    );

    expect(await database.readChapters.count(), 3);
    expect(await repo.readChapterIds(source: 'src', comicId: 'c1'), {
      'ch1',
      'ch2',
    });
  });

  test('写入后按漫画 key 通知详情页刷新', () async {
    final repo = ComicReadChapterRepository.instance;
    final change = repo.changes.first;
    await repo.markRead(
      source: 'src',
      comicId: 'c3',
      chapterId: 'ch1',
      chapterTitle: '第 1 话',
      chapterOrder: 1,
    );
    expect(await change, 'src:c3');
  });

  test('阅读器就绪时把当前章节写入已读', () async {
    final service = ReaderHistoryService.instance;
    await service.loadHistory(
      source: 'src',
      comicId: 'c9',
      comicInfo: const NormalComicAllInfo(
        comicInfo: ComicInfo(
          id: 'c9',
          title: '测试漫画',
          titleMeta: [],
          description: '',
          cover: ComicImage(id: 'cover', url: 'url', name: 'cover'),
          metadata: [],
        ),
        eps: [],
        recommend: [],
      ),
    );
    service.startPeriodicSave(
      () => HistorySnapshot(
        pageIndex: 1,
        chapterOrder: 1,
        epInfo: NormalComicEpInfo(epId: 'ch9', epName: '第 9 话'),
      ),
    );
    service.markLoaded();
    service.markCurrentChapterRead();
    service.stop();

    Set<String> ids = const {};
    for (var i = 0; i < 40 && ids.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      ids = await ComicReadChapterRepository.instance.readChapterIds(
        source: 'src',
        comicId: 'c9',
      );
    }
    expect(ids, {'ch9'});
  });

  test('周期保存直接写入历史', () async {
    final service = ReaderHistoryService.instance;
    await service.loadHistory(
      source: 'src',
      comicId: 'c10',
      comicInfo: const NormalComicAllInfo(
        comicInfo: ComicInfo(
          id: 'c10',
          title: '后台写入测试',
          titleMeta: [],
          description: '',
          cover: ComicImage(id: 'cover', url: 'url', name: 'cover'),
          metadata: [],
        ),
        eps: [],
        recommend: [],
      ),
    );
    service.startPeriodicSave(
      () => HistorySnapshot(
        pageIndex: 4,
        chapterOrder: 2,
        epInfo: NormalComicEpInfo(epId: 'ch10', epName: '第 10 话'),
      ),
    );
    service.markLoaded();

    try {
      UnifiedComicHistory? history;
      for (var i = 0; i < 40 && history == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        history = await database.histories.getByKey('src:c10');
      }
      expect(history, isNotNull);
      expect(history?.pageIndex, 4);
    } finally {
      service.stop();
    }
  });
}
