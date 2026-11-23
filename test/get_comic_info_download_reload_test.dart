import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zephyr/cubit/string_select.dart';
import 'package:zephyr/main.dart';
import 'package:zephyr/object_box/model.dart';
import 'package:zephyr/page/comic_info/bloc/get_comic_info_bloc.dart';
import 'package:zephyr/type/enum.dart';

import 'test_helper.dart';

Map<String, dynamic> _detail({
  required String title,
  required String coverPath,
  List<Map<String, dynamic>> eps = const <Map<String, dynamic>>[],
}) => <String, dynamic>{
  'comicInfo': <String, dynamic>{
    'id': 'c1',
    'title': title,
    'titleMeta': <dynamic>[],
    'creator': <String, dynamic>{
      'id': '',
      'name': '',
      'avatar': <String, dynamic>{'id': '', 'url': '', 'name': ''},
    },
    'description': '',
    'cover': <String, dynamic>{
      'id': 'cover',
      'url': '',
      'name': '',
      'path': coverPath,
      'extern': <String, dynamic>{'path': coverPath},
    },
    'metadata': <dynamic>[],
    'extern': <String, dynamic>{},
  },
  'eps': eps,
  'recommend': <Map<String, dynamic>>[],
  'extern': <String, dynamic>{},
};

void main() {
  setUpAll(() async {
    await TestDatabaseHelper.setUpTestDatabase();
  });
  tearDownAll(() async {
    await TestDatabaseHelper.tearDownTestDatabase();
  });
  tearDown(TestDatabaseHelper.cleanComicFolderBoxes);

  test('下载详情重新加载会读到编辑后的 detailJson', () async {
    final record = createTestDownload('test:c1')
      ..comicId = 'c1'
      ..detailJson = jsonEncode(_detail(title: 'Old', coverPath: 'old.jpg'));
    await database.downloads.put(record);

    final bloc = GetComicInfoBloc(StringSelectCubit());
    addTearDown(bloc.close);

    bloc.add(
      const GetComicInfoEvent(
        comicId: 'c1',
        from: 'test',
        type: ComicEntryType.download,
      ),
    );
    var state = await bloc.stream.firstWhere(
      (s) => s.status == GetComicInfoStatus.success,
    );
    expect(state.allInfo!.comicInfo.title, 'Old');
    expect(state.allInfo!.comicInfo.cover.path, 'old.jpg');
    expect(state.localCollected, isFalse);

    record.detailJson = jsonEncode(_detail(title: 'New', coverPath: 'new.jpg'));
    await database.downloads.put(record);

    bloc.add(
      const GetComicInfoEvent(
        comicId: 'c1',
        from: 'test',
        type: ComicEntryType.download,
      ),
    );
    state = await bloc.stream.firstWhere(
      (s) => s.status == GetComicInfoStatus.success,
    );
    expect(state.allInfo!.comicInfo.title, 'New');
    expect(state.allInfo!.comicInfo.cover.path, 'new.jpg');
  });

  test('本地收藏状态与详情同一次 success 返回', () async {
    final record = createTestDownload('test:c2')
      ..comicId = 'c2'
      ..detailJson = jsonEncode(_detail(title: 'T', coverPath: 'c2.jpg'));
    await database.downloads.put(record);
    await database.favorites.put(createTestFavorite('test:c2'));

    final bloc = GetComicInfoBloc(StringSelectCubit());
    addTearDown(bloc.close);
    bloc.add(
      const GetComicInfoEvent(
        comicId: 'c2',
        from: 'test',
        type: ComicEntryType.download,
      ),
    );
    final state = await bloc.stream.firstWhere(
      (s) => s.status == GetComicInfoStatus.success,
    );
    expect(state.localCollected, isTrue);
  });

  test('记录 comicId 与查询键不一致时按解析后的 comicId 查收藏', () async {
    final record = createTestDownload('test:lookup-key')
      ..comicId = 'c9'
      ..detailJson = jsonEncode(_detail(title: 'C9', coverPath: 'c9.jpg'));
    await database.downloads.put(record);
    await database.favorites.put(createTestFavorite('test:c9'));

    final bloc = GetComicInfoBloc(StringSelectCubit());
    addTearDown(bloc.close);
    bloc.add(
      const GetComicInfoEvent(
        comicId: 'lookup-key',
        from: 'test',
        type: ComicEntryType.download,
      ),
    );
    final state = await bloc.stream.firstWhere(
      (s) => s.status == GetComicInfoStatus.success,
    );
    expect(state.comicId, 'c9');
    expect(state.localCollected, isTrue);
  });

  test('阅读历史摘要与已读章节随详情同一次 success 返回', () async {
    final readAt = DateTime.utc(2026, 1, 2, 3, 4, 5);
    final record = createTestDownload('test:c3')
      ..comicId = 'c3'
      ..detailJson = jsonEncode(
        _detail(
          title: 'History',
          coverPath: 'c3.jpg',
          eps: <Map<String, dynamic>>[
            <String, dynamic>{'id': 'ch1', 'name': '第1话', 'order': 3},
          ],
        ),
      );
    await database.downloads.put(record);
    await database.histories.put(
      createTestHistory('test:c3')
        ..chapterId = 'ch1'
        ..chapterTitle = '第1话'
        ..chapterOrder = 3
        ..pageIndex = 5
        ..lastReadAt = readAt,
    );
    await database.readChapters.put(
      ComicReadChapter(
        uniqueKey: comicReadChapterUniqueKey('test', 'c3', 'ch1'),
        source: 'test',
        comicId: 'c3',
        chapterId: 'ch1',
        chapterTitle: '第1话',
        chapterOrder: 3,
        readAt: readAt,
        updatedAt: readAt,
      ),
    );

    final cubit = StringSelectCubit();
    final bloc = GetComicInfoBloc(cubit);
    addTearDown(bloc.close);
    bloc.add(
      const GetComicInfoEvent(
        comicId: 'c3',
        from: 'test',
        type: ComicEntryType.download,
      ),
    );
    final state = await bloc.stream.firstWhere(
      (s) => s.status == GetComicInfoStatus.success,
    );
    expect(state.readChapterIds, contains('ch1'));
    final expectedTime = readAt.toLocal().toString().substring(0, 19);
    expect(cubit.state, '3-第1话 / 4 / $expectedTime');
  });
}
