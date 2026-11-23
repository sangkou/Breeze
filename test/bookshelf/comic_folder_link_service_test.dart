import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zephyr/main.dart';
import 'package:zephyr/object_box/model.dart';
import 'package:zephyr/page/bookshelf/service/comic_folder_service.dart';
import 'package:zephyr/page/bookshelf/service/comic_link_service.dart';

import '../test_helper.dart';

/// 当前的 syncId -> folder 映射，供 [ComicFolderService.folderPath] 使用。
Future<Map<String, ComicFolder>> _folderMap() async {
  final all = await database.folders.getAll();
  return {for (final folder in all) folder.syncId: folder};
}

Future<String> _path(ComicFolder folder) async =>
    ComicFolderService.folderPath(folder, syncIdMap: await _folderMap());

void main() {
  setUpAll(TestDatabaseHelper.setUpTestDatabase);
  tearDownAll(TestDatabaseHelper.tearDownTestDatabase);
  tearDown(TestDatabaseHelper.cleanComicFolderBoxes);

  group('ComicFolderService', () {
    test('createFolder creates folder at root', () async {
      final folder = await ComicFolderService.createFolder(
        '',
        'folderA',
        ComicFolderType.favorite,
      );
      expect(folder.name, 'folderA');
      expect(folder.parentSyncId, isNull);
      expect(folder.typeData, ComicFolderType.favorite.name);
      expect(folder.syncId, isNotEmpty);
      expect(folder.deletedAt, isNull);
    });

    test('createFolder creates nested folder', () async {
      final parent = await ComicFolderService.createFolder(
        '',
        'parent',
        ComicFolderType.favorite,
      );
      final path = await _path(parent);
      final child = await ComicFolderService.createFolder(
        path,
        'child',
        ComicFolderType.favorite,
      );
      expect(child.parentSyncId, parent.syncId);
      expect(await _path(child), '/parent/child');
    });

    test('createFolder empty name throws', () async {
      await expectLater(
        ComicFolderService.createFolder('', '   ', ComicFolderType.favorite),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('createFolder name with slash throws', () async {
      await expectLater(
        ComicFolderService.createFolder('', 'a/b', ComicFolderType.favorite),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('createFolder duplicate active throws', () async {
      await ComicFolderService.createFolder(
        '',
        'dup',
        ComicFolderType.favorite,
      );
      await expectLater(
        ComicFolderService.createFolder('', 'dup', ComicFolderType.favorite),
        throwsA(isA<StateError>()),
      );
    });

    test('createFolder resurrects tombstone', () async {
      final folder = await ComicFolderService.createFolder(
        '',
        'res',
        ComicFolderType.favorite,
      );
      final path = await _path(folder);
      await ComicFolderService.deleteFolder(path, ComicFolderType.favorite);

      final resurrected = await ComicFolderService.createFolder(
        '',
        'res',
        ComicFolderType.favorite,
      );
      expect(resurrected.id, folder.id);
      expect(resurrected.deletedAt, isNull);
      expect(resurrected.syncId, folder.syncId);
    });

    test('renameFolder updates name and uniqueKey', () async {
      final folder = await ComicFolderService.createFolder(
        '',
        'old',
        ComicFolderType.favorite,
      );
      final path = await _path(folder);
      await ComicFolderService.renameFolder(
        path,
        'new',
        ComicFolderType.favorite,
      );

      final renamed = await database.folders.getById(folder.id);
      expect(renamed!.name, 'new');
      expect(await _path(renamed), '/new');
    });

    test('renameFolder duplicate active throws', () async {
      await ComicFolderService.createFolder('', 'a', ComicFolderType.favorite);
      final b = await ComicFolderService.createFolder(
        '',
        'b',
        ComicFolderType.favorite,
      );
      final bPath = await _path(b);
      await expectLater(
        ComicFolderService.renameFolder(bPath, 'a', ComicFolderType.favorite),
        throwsA(isA<StateError>()),
      );
    });

    test('renameFolder removes conflicting tombstone', () async {
      final a = await ComicFolderService.createFolder(
        '',
        'a',
        ComicFolderType.favorite,
      );
      final aPath = await _path(a);
      await ComicFolderService.deleteFolder(aPath, ComicFolderType.favorite);

      final b = await ComicFolderService.createFolder(
        '',
        'b',
        ComicFolderType.favorite,
      );
      final bPath = await _path(b);
      await ComicFolderService.renameFolder(
        bPath,
        'a',
        ComicFolderType.favorite,
      );

      expect(await database.folders.getById(a.id), isNull);
      expect((await database.folders.getById(b.id))!.name, 'a');
    });

    test('deleteFolder soft deletes folder and descendants', () async {
      final parent = await ComicFolderService.createFolder(
        '',
        'parent',
        ComicFolderType.favorite,
      );
      final parentPath = await _path(parent);
      final child = await ComicFolderService.createFolder(
        parentPath,
        'child',
        ComicFolderType.favorite,
      );

      await ComicFolderService.deleteFolder(
        parentPath,
        ComicFolderType.favorite,
      );

      expect((await database.folders.getById(parent.id))!.deletedAt, isNotNull);
      expect((await database.folders.getById(child.id))!.deletedAt, isNotNull);
    });

    test('deleteFolder does not delete root', () async {
      await ComicFolderService.deleteFolder('', ComicFolderType.favorite);
      // No exception and nothing to assert; root has no entity.
      expect(true, isTrue);
    });

    test('batchMoveFolders moves folder to new parent', () async {
      final a = await ComicFolderService.createFolder(
        '',
        'a',
        ComicFolderType.favorite,
      );
      final aPath = await _path(a);
      final b = await ComicFolderService.createFolder(
        '',
        'b',
        ComicFolderType.favorite,
      );
      final bPath = await _path(b);

      await ComicFolderService.batchMoveFolders(
        {aPath},
        bPath,
        ComicFolderType.favorite,
      );

      final moved = await database.folders.getById(a.id);
      expect(moved!.parentSyncId, b.syncId);
      expect(await _path(moved), '/b/a');
    });

    test('batchMoveFolders prevents moving into self', () async {
      final a = await ComicFolderService.createFolder(
        '',
        'a',
        ComicFolderType.favorite,
      );
      final aPath = await _path(a);
      await expectLater(
        ComicFolderService.batchMoveFolders(
          {aPath},
          aPath,
          ComicFolderType.favorite,
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('batchMoveFolders prevents moving into descendant', () async {
      final a = await ComicFolderService.createFolder(
        '',
        'a',
        ComicFolderType.favorite,
      );
      final aPath = await _path(a);
      final child = await ComicFolderService.createFolder(
        aPath,
        'child',
        ComicFolderType.favorite,
      );
      final childPath = await _path(child);
      await expectLater(
        ComicFolderService.batchMoveFolders(
          {aPath},
          childPath,
          ComicFolderType.favorite,
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('batchCopyFolders copies folder recursively with links', () async {
      final favorite = createTestFavorite('test:comic1');
      await database.favorites.put(favorite);

      final src = await ComicFolderService.createFolder(
        '',
        'src',
        ComicFolderType.favorite,
      );
      final srcPath = await _path(src);
      await ComicFolderService.createFolder(
        srcPath,
        'child',
        ComicFolderType.favorite,
      );
      await ComicLinkService.addComic(
        'test:comic1',
        srcPath,
        ComicFolderType.favorite,
      );

      await ComicFolderService.batchCopyFolders(
        {srcPath},
        '',
        ComicFolderType.favorite,
      );

      final rootFolders = await ComicFolderService.listChildFolders(
        '',
        ComicFolderType.favorite,
      );
      expect(rootFolders.length, 2);

      final copied = rootFolders.firstWhere((f) => f.syncId != src.syncId);
      final copiedPath = await _path(copied);
      final copiedLinks = await ComicLinkService.listLinks(
        copiedPath,
        ComicFolderType.favorite,
      );
      expect(copiedLinks.length, 1);
      expect(copiedLinks.first.comicUniqueKey, 'test:comic1');
    });
  });

  group('ComicLinkService', () {
    test('addComic creates link at root', () async {
      final link = await ComicLinkService.addComic(
        'test:comic1',
        null,
        ComicFolderType.favorite,
      );
      expect(link.folderSyncId, isNull);
      expect(link.comicUniqueKey, 'test:comic1');
      expect(link.deletedAt, isNull);
    });

    test('addComic creates link in folder', () async {
      final folder = await ComicFolderService.createFolder(
        '',
        'f',
        ComicFolderType.favorite,
      );
      final path = await _path(folder);
      final link = await ComicLinkService.addComic(
        'test:comic1',
        path,
        ComicFolderType.favorite,
      );
      expect(link.folderSyncId, folder.syncId);
    });

    test('addComic resurrects tombstone', () async {
      final folder = await ComicFolderService.createFolder(
        '',
        'f',
        ComicFolderType.favorite,
      );
      final path = await _path(folder);
      final link = await ComicLinkService.addComic(
        'test:comic1',
        path,
        ComicFolderType.favorite,
      );
      await ComicLinkService.removeComic(
        'test:comic1',
        path,
        ComicFolderType.favorite,
      );

      final resurrected = await ComicLinkService.addComic(
        'test:comic1',
        path,
        ComicFolderType.favorite,
      );
      expect(resurrected.id, link.id);
      expect(resurrected.deletedAt, isNull);
    });

    test('removeComic soft deletes favorite link', () async {
      final link = await ComicLinkService.addComic(
        'test:comic1',
        null,
        ComicFolderType.favorite,
      );
      await ComicLinkService.removeComic(
        'test:comic1',
        null,
        ComicFolderType.favorite,
      );

      final stored = await database.links.getById(link.id);
      expect(stored!.deletedAt, isNotNull);
    });

    test('removeComic marks favorite deleted when last link', () async {
      final favorite = createTestFavorite('test:comic1');
      await database.favorites.put(favorite);
      await ComicLinkService.addComic(
        'test:comic1',
        null,
        ComicFolderType.favorite,
      );

      await ComicLinkService.removeComic(
        'test:comic1',
        null,
        ComicFolderType.favorite,
      );

      final stored = await database.favorites.getById(favorite.id);
      expect(stored!.deleted, isTrue);
    });

    test(
      'removeComic does not mark favorite deleted when other links exist',
      () async {
        final favorite = createTestFavorite('test:comic1');
        await database.favorites.put(favorite);
        final f1 = await ComicFolderService.createFolder(
          '',
          'f1',
          ComicFolderType.favorite,
        );
        final f2 = await ComicFolderService.createFolder(
          '',
          'f2',
          ComicFolderType.favorite,
        );
        await ComicLinkService.addComic(
          'test:comic1',
          await _path(f1),
          ComicFolderType.favorite,
        );
        await ComicLinkService.addComic(
          'test:comic1',
          await _path(f2),
          ComicFolderType.favorite,
        );

        await ComicLinkService.removeComic(
          'test:comic1',
          await _path(f1),
          ComicFolderType.favorite,
        );

        final stored = await database.favorites.getById(favorite.id);
        expect(stored!.deleted, isFalse);
      },
    );

    test('removeComic physical deletes download link', () async {
      await ComicLinkService.addComic(
        'test:comic1',
        null,
        ComicFolderType.download,
      );
      await ComicLinkService.removeComic(
        'test:comic1',
        null,
        ComicFolderType.download,
      );

      final remaining = await database.links.getAll();
      expect(remaining, isEmpty);
    });

    test('removeComic deletes download files when last link', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'breeze_download_test_',
      );
      final download = createTestDownload(
        'test:comic1',
        storageRoot: tempDir.path,
      );
      await database.downloads.put(download);
      await ComicLinkService.addComic(
        'test:comic1',
        null,
        ComicFolderType.download,
      );

      await ComicLinkService.removeComic(
        'test:comic1',
        null,
        ComicFolderType.download,
      );

      expect(await database.downloads.getById(download.id), isNull);
      expect(await tempDir.exists(), isFalse);
    });

    test('moveComic moves link without marking favorite deleted', () async {
      final favorite = createTestFavorite('test:comic1');
      await database.favorites.put(favorite);
      final f1 = await ComicFolderService.createFolder(
        '',
        'f1',
        ComicFolderType.favorite,
      );
      final f2 = await ComicFolderService.createFolder(
        '',
        'f2',
        ComicFolderType.favorite,
      );
      final f1Path = await _path(f1);
      final f2Path = await _path(f2);
      await ComicLinkService.addComic(
        'test:comic1',
        f1Path,
        ComicFolderType.favorite,
      );

      await ComicLinkService.moveComic(
        'test:comic1',
        f1Path,
        f2Path,
        ComicFolderType.favorite,
      );

      final links = await ComicLinkService.listLinks(
        f2Path,
        ComicFolderType.favorite,
      );
      expect(links.length, 1);
      expect((await database.favorites.getById(favorite.id))!.deleted, isFalse);
    });

    test('removeComicFromAll removes all links', () async {
      final f1 = await ComicFolderService.createFolder(
        '',
        'f1',
        ComicFolderType.favorite,
      );
      final f2 = await ComicFolderService.createFolder(
        '',
        'f2',
        ComicFolderType.favorite,
      );
      await ComicLinkService.addComic(
        'test:comic1',
        await _path(f1),
        ComicFolderType.favorite,
      );
      await ComicLinkService.addComic(
        'test:comic1',
        await _path(f2),
        ComicFolderType.favorite,
      );

      await ComicLinkService.removeComicFromAll(
        'test:comic1',
        ComicFolderType.favorite,
      );

      expect(
        await ComicLinkService.linksOfComic(
          'test:comic1',
          ComicFolderType.favorite,
        ),
        isEmpty,
      );
    });

    test('removeLinksInFolderTree removes links in subtree', () async {
      final parent = await ComicFolderService.createFolder(
        '',
        'parent',
        ComicFolderType.favorite,
      );
      final parentPath = await _path(parent);
      final child = await ComicFolderService.createFolder(
        parentPath,
        'child',
        ComicFolderType.favorite,
      );
      final childPath = await _path(child);
      await ComicLinkService.addComic(
        'test:comic1',
        childPath,
        ComicFolderType.favorite,
      );

      await ComicLinkService.removeLinksInFolderTree(
        parentPath,
        ComicFolderType.favorite,
      );

      expect(
        await ComicLinkService.linksOfComic(
          'test:comic1',
          ComicFolderType.favorite,
        ),
        isEmpty,
      );
    });
  });

  group('folder deletion link cleanup', () {
    test(
      'deleting a folder removes links inside it and unfavorites comic',
      () async {
        final favorite = createTestFavorite('test:comic1');
        await database.favorites.put(favorite);
        final folder = await ComicFolderService.createFolder(
          '',
          'folder',
          ComicFolderType.favorite,
        );
        final path = await _path(folder);
        await ComicLinkService.addComic(
          'test:comic1',
          path,
          ComicFolderType.favorite,
        );

        // This mimics what FolderShelfBloc does on folder delete.
        await ComicFolderService.deleteFolder(path, ComicFolderType.favorite);
        await ComicLinkService.removeLinksInFolderTree(
          path,
          ComicFolderType.favorite,
        );

        expect(
          await ComicLinkService.linksOfComic(
            'test:comic1',
            ComicFolderType.favorite,
          ),
          isEmpty,
        );
        expect(
          (await database.favorites.getById(favorite.id))!.deleted,
          isTrue,
        );
      },
    );

    test('deleting a parent folder removes links in nested folders and unfavorites comic', () async {
      final favorite = createTestFavorite('test:comic1');
      await database.favorites.put(favorite);
      final parent = await ComicFolderService.createFolder(
        '',
        'parent',
        ComicFolderType.favorite,
      );
      final parentPath = await _path(parent);
      final child = await ComicFolderService.createFolder(
        parentPath,
        'child',
        ComicFolderType.favorite,
      );
      final childPath = await _path(child);
      await ComicLinkService.addComic(
        'test:comic1',
        childPath,
        ComicFolderType.favorite,
      );

      await ComicFolderService.deleteFolder(
        parentPath,
        ComicFolderType.favorite,
      );
      await ComicLinkService.removeLinksInFolderTree(
        parentPath,
        ComicFolderType.favorite,
      );

      expect(
        await ComicLinkService.linksOfComic(
          'test:comic1',
          ComicFolderType.favorite,
        ),
        isEmpty,
      );
      expect((await database.favorites.getById(favorite.id))!.deleted, isTrue);
    });
  });

  group('ComicFolderService edge cases', () {
    test('folderPath handles self-referencing cycle gracefully', () async {
      final folder = await ComicFolderService.createFolder(
        '',
        'loop',
        ComicFolderType.favorite,
      );
      // Manufacture a self-reference cycle.
      folder.parentSyncId = folder.syncId;
      await database.folders.put(folder);

      // Should not infinite loop; returns partial path.
      final path = await _path(folder);
      expect(path, startsWith('/loop'));
    });

    test('folderPath handles mutual cycle gracefully', () async {
      final a = await ComicFolderService.createFolder(
        '',
        'a',
        ComicFolderType.favorite,
      );
      final b = await ComicFolderService.createFolder(
        '',
        'b',
        ComicFolderType.favorite,
      );
      a.parentSyncId = b.syncId;
      b.parentSyncId = a.syncId;
      await database.folders.putMany([a, b]);

      // Should not infinite loop.
      final pathA = await _path(a);
      final pathB = await _path(b);
      expect(pathA, isNotEmpty);
      expect(pathB, isNotEmpty);
    });

    test('deleteFolder handles deeply nested tree', () async {
      const depth = 100;
      final root = await ComicFolderService.createFolder(
        '',
        'root',
        ComicFolderType.favorite,
      );
      var path = await _path(root);
      for (var i = 1; i < depth; i++) {
        final current = await ComicFolderService.createFolder(
          path,
          'level$i',
          ComicFolderType.favorite,
        );
        path = await _path(current);
      }

      await ComicFolderService.deleteFolder(
        await _path(root),
        ComicFolderType.favorite,
      );

      final all = await database.folders.getAll();
      expect(all.length, depth);
      expect(all.every((f) => f.deletedAt != null), isTrue);
    });

    test('batchMoveFolders ignores child when parent is also moved', () async {
      final parent = await ComicFolderService.createFolder(
        '',
        'parent',
        ComicFolderType.favorite,
      );
      final parentPath = await _path(parent);
      final child = await ComicFolderService.createFolder(
        parentPath,
        'child',
        ComicFolderType.favorite,
      );
      final childPath = await _path(child);
      final target = await ComicFolderService.createFolder(
        '',
        'target',
        ComicFolderType.favorite,
      );
      final targetPath = await _path(target);

      // Move both parent and child to target. Child is already moving with parent.
      await ComicFolderService.batchMoveFolders(
        {parentPath, childPath},
        targetPath,
        ComicFolderType.favorite,
      );

      final storedParent = await database.folders.getById(parent.id);
      final storedChild = await database.folders.getById(child.id);
      expect(storedParent!.parentSyncId, target.syncId);
      expect(storedChild!.parentSyncId, parent.syncId);
      expect(await _path(storedChild), '/target/parent/child');
    });

    test('batchDeleteFolders deletes parent and all descendants', () async {
      final parent = await ComicFolderService.createFolder(
        '',
        'parent',
        ComicFolderType.favorite,
      );
      final parentPath = await _path(parent);
      final child = await ComicFolderService.createFolder(
        parentPath,
        'child',
        ComicFolderType.favorite,
      );
      final childPath = await _path(child);

      await ComicFolderService.batchDeleteFolders({
        parentPath,
        childPath,
      }, ComicFolderType.favorite);

      expect((await database.folders.getById(parent.id))!.deletedAt, isNotNull);
      expect((await database.folders.getById(child.id))!.deletedAt, isNotNull);
    });

    test(
      'createFolder under deleted parent falls back to root semantics',
      () async {
        final parent = await ComicFolderService.createFolder(
          '',
          'parent',
          ComicFolderType.favorite,
        );
        final parentPath = await _path(parent);
        await ComicFolderService.deleteFolder(
          parentPath,
          ComicFolderType.favorite,
        );

        // Attempting to create under the deleted parent path cannot find active parent,
        // so it ends up creating at root level with a different uniqueKey.
        final created = await ComicFolderService.createFolder(
          parentPath,
          'child',
          ComicFolderType.favorite,
        );
        expect(created.parentSyncId, isNull);
        expect(await _path(created), '/child');
      },
    );
  });

  group('ComicLinkService edge cases', () {
    test('addComic to deleted folder falls back to root', () async {
      final folder = await ComicFolderService.createFolder(
        '',
        'f',
        ComicFolderType.favorite,
      );
      final path = await _path(folder);
      await ComicFolderService.deleteFolder(path, ComicFolderType.favorite);

      final link = await ComicLinkService.addComic(
        'test:comic1',
        path,
        ComicFolderType.favorite,
      );
      expect(link.folderSyncId, isNull);
    });

    test('removeComic from deleted folder removes root-level link', () async {
      final folder = await ComicFolderService.createFolder(
        '',
        'f',
        ComicFolderType.favorite,
      );
      final path = await _path(folder);
      await ComicLinkService.addComic(
        'test:comic1',
        path,
        ComicFolderType.favorite,
      );
      await ComicFolderService.deleteFolder(path, ComicFolderType.favorite);

      // Removing by the deleted path should operate on root-level fallback link.
      await ComicLinkService.removeComic(
        'test:comic1',
        path,
        ComicFolderType.favorite,
      );

      expect(
        await ComicLinkService.linksOfComic(
          'test:comic1',
          ComicFolderType.favorite,
        ),
        isEmpty,
      );
    });

    test('moveComic to same folder is no-op', () async {
      final folder = await ComicFolderService.createFolder(
        '',
        'f',
        ComicFolderType.favorite,
      );
      final path = await _path(folder);
      final link = await ComicLinkService.addComic(
        'test:comic1',
        path,
        ComicFolderType.favorite,
      );

      await ComicLinkService.moveComic(
        'test:comic1',
        path,
        path,
        ComicFolderType.favorite,
      );

      expect(
        (await ComicLinkService.listLinks(
          path,
          ComicFolderType.favorite,
        )).length,
        1,
      );
      expect(
        (await ComicLinkService.listLinks(
          path,
          ComicFolderType.favorite,
        )).single.id,
        link.id,
      );
    });

    test('batchMoveComics with empty set does nothing', () async {
      final folder = await ComicFolderService.createFolder(
        '',
        'f',
        ComicFolderType.favorite,
      );
      await ComicLinkService.batchMoveComics(
        {},
        await _path(folder),
        '',
        ComicFolderType.favorite,
      );
      expect(true, isTrue);
    });

    test('removeComicFromAll with no links does not throw', () async {
      await ComicLinkService.removeComicFromAll(
        'nonexistent:comic',
        ComicFolderType.favorite,
      );
      expect(true, isTrue);
    });

    test('links are isolated across folder types', () async {
      final folderFav = await ComicFolderService.createFolder(
        '',
        'fav',
        ComicFolderType.favorite,
      );
      final folderHist = await ComicFolderService.createFolder(
        '',
        'hist',
        ComicFolderType.history,
      );
      await ComicLinkService.addComic(
        'test:comic1',
        await _path(folderFav),
        ComicFolderType.favorite,
      );
      await ComicLinkService.addComic(
        'test:comic1',
        await _path(folderHist),
        ComicFolderType.history,
      );

      expect(
        (await ComicLinkService.listLinks(
          await _path(folderFav),
          ComicFolderType.favorite,
        )).length,
        1,
      );
      expect(
        (await ComicLinkService.listLinks(
          await _path(folderHist),
          ComicFolderType.history,
        )).length,
        1,
      );
    });
  });

  group('download folder edge cases', () {
    test('delete download folder removes nested files', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'breeze_download_nested_',
      );
      final nestedDir = Directory('${tempDir.path}/chapters');
      await nestedDir.create();
      await File('${nestedDir.path}/01.jpg').writeAsString('fake');

      final download = createTestDownload(
        'test:comic1',
        storageRoot: tempDir.path,
      );
      await database.downloads.put(download);

      final folder = await ComicFolderService.createFolder(
        '',
        'downloads',
        ComicFolderType.download,
      );
      final path = await _path(folder);
      await ComicLinkService.addComic(
        'test:comic1',
        path,
        ComicFolderType.download,
      );

      await ComicFolderService.deleteFolder(path, ComicFolderType.download);
      await ComicLinkService.removeLinksInFolderTree(
        path,
        ComicFolderType.download,
      );

      expect(await tempDir.exists(), isFalse);
      expect(await database.downloads.getById(download.id), isNull);
    });
  });
}
