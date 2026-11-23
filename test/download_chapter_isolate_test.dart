import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zephyr/main.dart';
import 'package:zephyr/object_box/model.dart';
import 'package:zephyr/page/comic_read/method/get_local_info.dart';
import 'package:zephyr/service/download/download_chapter_isolate.dart';
import 'package:zephyr/service/download/download_task_repository.dart';
import 'package:zephyr/util/async/worker_pool.dart';

import 'test_helper.dart';

String _chaptersJson() => jsonEncode([
  {
    'id': 'c1',
    'name': '第一话',
    'order': 1,
    'images': [
      {
        'id': 'i1',
        'name': '1.jpg',
        'path': '/p/c1/1.jpg',
        'url': 'https://x/1.jpg',
      },
      {
        'id': 'i2',
        'name': '2.jpg',
        'path': '/p/c1/2.jpg',
        'url': 'https://x/2.jpg',
      },
    ],
  },
  {
    'id': 'c2',
    'name': '第二话',
    'order': 2,
    'images': [
      {
        'id': 'i3',
        'name': '1.jpg',
        'path': '/p/c2/1.jpg',
        'url': 'https://x/3.jpg',
      },
    ],
  },
  {
    'id': 'c3',
    'name': '第三话',
    'order': 3,
    'images': [
      {
        'id': 'i4',
        'name': '1.jpg',
        'path': '/p/c3/1.jpg',
        'url': 'https://x/4.jpg',
      },
    ],
  },
]);

void main() {
  setUpAll(TestDatabaseHelper.setUpTestDatabase);
  tearDownAll(TestDatabaseHelper.tearDownTestDatabase);
  tearDown(TestDatabaseHelper.cleanComicFolderBoxes);

  test(
    'lookupDownloadedChapter matches keys/order and can include record',
    () async {
      await database.downloads.put(
        UnifiedComicDownload.fromJson(<String, dynamic>{
          'uniqueKey': 'test:123',
          'source': 'test',
          'comicId': '123',
          'title': '漫画',
          'chapters': _chaptersJson(),
        }),
      );
      const repository = DownloadTaskRepository();

      final byKey = await repository.lookupDownloadedChapter(
        from: 'test',
        comicId: '123',
        chapterKeys: <String>['c2'],
      );
      expect(byKey.chapter?.id, 'c2');
      expect(byKey.chapter?.order, 2);
      expect(byKey.chapterCount, 3);
      expect(byKey.record, isNull);

      final withRecord = await repository.lookupDownloadedChapter(
        from: 'test',
        comicId: '123',
        chapterKeys: <String>['c2'],
        includeRecord: true,
      );
      expect(withRecord.chapter?.id, 'c2');
      expect(withRecord.record?.uniqueKey, 'test:123');
      expect(withRecord.record?.chapters, isNotEmpty);

      final byOrder = await repository.lookupDownloadedChapter(
        from: 'test',
        comicId: '123',
        chapterKeys: <String>['missing'],
        order: 3,
        fallbackFirst: true,
      );
      expect(byOrder.chapter?.id, 'c3');
      expect(byOrder.chapterCount, 3);

      final miss = await repository.lookupDownloadedChapter(
        from: 'test',
        comicId: '123',
        chapterKeys: <String>['missing'],
      );
      expect(miss.chapter, isNull);
      expect(miss.chapterCount, 3);

      final missingRecord = await repository.lookupDownloadedChapter(
        from: 'test',
        comicId: '404',
        chapterKeys: <String>['c1'],
      );
      expect(missingRecord.chapter, isNull);
      expect(missingRecord.chapterCount, 0);
    },
  );

  test('getPluginInfoFromLocal resolves docs in the worker isolate', () async {
    await database.downloads.put(
      UnifiedComicDownload.fromJson(<String, dynamic>{
        'uniqueKey': 'test:123',
        'source': 'test',
        'comicId': '123',
        'title': '漫画',
        'chapters': _chaptersJson(),
      }),
    );

    final info = await getPluginInfoFromLocal('test', '123', 2);
    expect(info.epId, 'c2');
    expect(info.epName, '第二话');
    expect(info.docs, hasLength(1));
    expect(info.docs.single.path, '/p/c2/1.jpg');

    await expectLater(
      getPluginInfoFromLocal('test', '404', 1),
      throwsA(isA<StateError>()),
    );
  });

  test('下载详情在 worker 池解析并按目录快照排序', () async {
    final detailJson = jsonEncode({
      'comicInfo': {
        'id': '123',
        'title': '漫画',
        'titleMeta': <dynamic>[],
        'description': '简介',
        'cover': {'id': 'cover', 'url': 'https://x/c.jpg', 'name': 'c.jpg'},
        'metadata': <dynamic>[],
      },
      'eps': [
        {'id': 'c3', 'name': '第三话', 'order': 3},
        {'id': 'c1', 'name': '第一话', 'order': 1},
        {'id': 'c2', 'name': '第二话', 'order': 2},
      ],
      'recommend': <dynamic>[],
      // 目录快照：详情页据此把已下载章节排回线上顺序。
      'extern': {
        'chapterCatalog': [
          {'id': 'c1', 'name': '第一话', 'order': 1},
          {'id': 'c2', 'name': '第二话', 'order': 2},
          {'id': 'c3', 'name': '第三话', 'order': 3},
        ],
      },
    });
    await database.downloads.put(
      UnifiedComicDownload.fromJson(<String, dynamic>{
        'uniqueKey': 'test:123',
        'source': 'test',
        'comicId': '123',
        'title': '漫画',
        'chapters': _chaptersJson(),
        'detailJson': detailJson,
      }),
    );

    // 生产路径：详情页把整段读取+解析交给后台 isolate。
    final task = DownloadComicInfoTask(
      handle: database.db.handle,
      downloadKey: 'test:123',
    );
    final result = await runInIsolate(readDownloadedComicInfoInWorker, task);

    expect(result.record?.uniqueKey, 'test:123');
    expect(result.info?.comicInfo.title, '漫画');
    expect(result.info?.eps.map((ep) => ep.id).toList(), <String>[
      'c1',
      'c2',
      'c3',
    ]);

    final missing = await runInIsolate(
      readDownloadedComicInfoInWorker,
      DownloadComicInfoTask(handle: task.handle, downloadKey: 'test:404'),
    );
    expect(missing.record, isNull);
    expect(missing.info, isNull);
  });

  test('已下载章节 id 在 worker 池解析，缺失记录返回空集合', () async {
    await database.downloads.put(
      UnifiedComicDownload.fromJson(<String, dynamic>{
        'uniqueKey': 'test:123',
        'source': 'test',
        'comicId': '123',
        'title': '漫画',
        'chapters': _chaptersJson(),
      }),
    );

    const repository = DownloadTaskRepository();
    final ids = await repository.downloadedChapterIds(
      from: 'test',
      comicId: '123',
    );
    expect(ids, <String>{'c1', 'c2', 'c3'});

    final missing = await repository.downloadedChapterIds(
      from: 'test',
      comicId: '404',
    );
    expect(missing, isEmpty);
  });
}
