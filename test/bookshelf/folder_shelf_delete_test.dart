import 'package:flutter_test/flutter_test.dart';
import 'package:zephyr/main.dart';
import 'package:zephyr/object_box/model.dart';
import 'package:zephyr/page/bookshelf/bloc/folder_shelf_bloc.dart';
import 'package:zephyr/page/bookshelf/models/shelf_page_mode.dart';
import 'package:zephyr/page/bookshelf/service/comic_folder_service.dart';
import 'package:zephyr/page/bookshelf/service/comic_link_service.dart';

import '../test_helper.dart';

Future<void> _waitFor(bool Function() condition, String reason) async {
  for (var i = 0; i < 400; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('timeout waiting for: $reason');
}

Future<void> _waitDb(Future<bool> Function() condition, String reason) async {
  for (var i = 0; i < 400; i++) {
    if (await condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('timeout waiting for: $reason');
}

Future<UnifiedComicFavorite> _seedFavorite(String comicId) async {
  final favorite = createTestFavorite('test:$comicId')..comicId = comicId;
  await database.favorites.put(favorite);
  return favorite;
}

void main() {
  setUpAll(TestDatabaseHelper.setUpTestDatabase);
  tearDownAll(TestDatabaseHelper.tearDownTestDatabase);
  tearDown(TestDatabaseHelper.cleanComicFolderBoxes);

  test('删除文件夹：软删文件夹树、移除链接并刷新列表', () async {
    await _seedFavorite('c1');
    final folder = await ComicFolderService.createFolder(
      '',
      'A',
      ComicFolderType.favorite,
    );
    await ComicLinkService.addComic('test:c1', '/A', ComicFolderType.favorite);

    final bloc = FolderShelfBloc(mode: ShelfPageMode.favorite);
    addTearDown(bloc.close);
    bloc.add(const FolderShelfLoadRequested());
    await _waitFor(
      () => bloc.state.folders.any((f) => f.name == 'A'),
      'root folder A',
    );
    expect(bloc.state.folderComicCounts['/A'], 1);

    bloc.add(const FolderShelfEnterFolder('/A'));
    await _waitFor(
      () => bloc.state.currentPath == '/A' && bloc.state.comics.length == 1,
      'comic inside /A',
    );

    bloc.add(const FolderShelfDeleteFolder('/A'));
    await _waitDb(
      () async =>
          (await database.folders.getById(folder.id))?.deletedAt != null,
      'folder soft deleted',
    );
    await _waitFor(
      () =>
          !bloc.state.isLoading &&
          !bloc.state.isLoadingMore &&
          bloc.state.comics.isEmpty &&
          bloc.state.folders.isEmpty,
      'reload finished',
    );
    expect(bloc.state.error, isNull);
    expect(
      await database.links.listActiveByType(ComicFolderType.favorite.name),
      isEmpty,
    );
    expect((await database.favorites.getByKey('test:c1'))!.deleted, isTrue);
  });

  test('删除选中漫画：移除根目录链接并软删收藏本体', () async {
    await _seedFavorite('c1');
    await ComicLinkService.addComic('test:c1', null, ComicFolderType.favorite);

    final bloc = FolderShelfBloc(mode: ShelfPageMode.favorite);
    addTearDown(bloc.close);
    bloc.add(const FolderShelfLoadRequested());
    await _waitFor(() => bloc.state.comics.length == 1, 'root comic loaded');

    bloc.add(const FolderShelfToggleComicSelection('test:c1'));
    await _waitFor(
      () => bloc.state.selectedComicKeys.contains('test:c1'),
      'comic selected',
    );

    bloc.add(const FolderShelfDeleteSelected());
    await _waitDb(
      () async => (await database.favorites.getByKey('test:c1'))!.deleted,
      'favorite soft deleted',
    );
    await _waitFor(
      () =>
          !bloc.state.selectionMode &&
          !bloc.state.isLoading &&
          bloc.state.comics.isEmpty,
      'selection cleared and shelf reloaded',
    );
    expect(bloc.state.error, isNull);
    expect(
      await database.links.listActiveByType(ComicFolderType.favorite.name),
      isEmpty,
    );
  });

  test('删除选中历史：软删历史本体并从列表消失', () async {
    final history = createTestHistory('test:h1')..comicId = 'h1';
    await database.histories.put(history);

    final bloc = FolderShelfBloc(mode: ShelfPageMode.history);
    addTearDown(bloc.close);
    bloc.add(const FolderShelfLoadRequested());
    await _waitFor(() => bloc.state.comics.length == 1, 'history loaded');

    bloc.add(const FolderShelfToggleComicSelection('test:h1'));
    await _waitFor(
      () => bloc.state.selectedComicKeys.contains('test:h1'),
      'history selected',
    );

    bloc.add(const FolderShelfDeleteSelected());
    await _waitDb(
      () async => (await database.histories.getByKey('test:h1'))!.deleted,
      'history soft deleted',
    );
    await _waitFor(
      () =>
          !bloc.state.selectionMode &&
          !bloc.state.isLoading &&
          bloc.state.comics.isEmpty,
      'history list reloaded',
    );
    expect(bloc.state.error, isNull);
  });

  test('移动选中漫画到文件夹后，根目录消失且子目录可见', () async {
    await _seedFavorite('c1');
    await ComicLinkService.addComic('test:c1', null, ComicFolderType.favorite);
    await ComicFolderService.createFolder('', 'A', ComicFolderType.favorite);
    final syncA = await ComicFolderService.folderSyncIdByPath(
      '/A',
      ComicFolderType.favorite,
    );

    final bloc = FolderShelfBloc(mode: ShelfPageMode.favorite);
    addTearDown(bloc.close);
    bloc.add(const FolderShelfLoadRequested());
    await _waitFor(() => bloc.state.comics.length == 1, 'root comic loaded');

    bloc.add(const FolderShelfToggleComicSelection('test:c1'));
    await _waitFor(
      () => bloc.state.selectedComicKeys.contains('test:c1'),
      'comic selected',
    );

    bloc.add(const FolderShelfMoveSelected(<String>{'/A'}));
    await _waitDb(() async {
      final inside = await database.links.listActiveByFolder(
        syncA,
        ComicFolderType.favorite.name,
      );
      final root = await database.links.listActiveByFolder(
        null,
        ComicFolderType.favorite.name,
      );
      return inside.length == 1 && root.isEmpty;
    }, 'comic moved into /A');
    await _waitFor(
      () =>
          !bloc.state.selectionMode &&
          !bloc.state.isLoading &&
          bloc.state.comics.isEmpty,
      'root reloaded',
    );

    bloc.add(const FolderShelfEnterFolder('/A'));
    await _waitFor(() => bloc.state.comics.length == 1, 'comic visible in /A');
    expect(bloc.state.error, isNull);
  });
}
