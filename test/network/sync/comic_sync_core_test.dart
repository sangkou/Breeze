import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zephyr/network/sync/comic_sync_core.dart';
import 'package:zephyr/network/sync/sync_device_id.dart';
import 'package:zephyr/object_box/model.dart';
import 'package:path/path.dart' as p;
import 'package:zephyr/database/database.dart';

void main() {
  late Directory tempDir;
  late Database database;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('breeze_sync_test_');
    database = await Database.open(
      path: p.join(tempDir.path, 'breeze.sqlite3'),
      legacyObjectBoxDir: p.join(tempDir.path, 'missing_objectbox'),
    );
    syncDeviceId = 'device_local';
  });

  tearDown(() async {
    await database.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<void> runMerge(
    Database database,
    Map<String, dynamic> data, {
    String deviceId = 'device_local',
  }) async {
    syncDeviceId = deviceId;
    await ComicSyncCore.mergeUnifiedData(database, data);
  }

  group('ComicSyncCore.mergeUnifiedData', () {
    test('merges favorites by LWW', () async {
      final localUpdated = DateTime.utc(2024, 1, 1, 12, 0);
      final cloudUpdated = DateTime.utc(2024, 1, 1, 13, 0);

      final local = createFavorite(
        'test:comic1',
        title: 'Local Title',
        updatedAt: localUpdated,
      );
      final cloud = createFavorite(
        'test:comic1',
        title: 'Cloud Title',
        updatedAt: cloudUpdated,
      );

      final data = buildPayload(favorites: [cloud.toJson()]);
      await putAll(database, favorites: [local]);

      await runMerge(database, data);

      final merged = (await database.favorites.getAll()).single;
      expect(merged.title, 'Cloud Title');
    });

    test('merges histories by LWW', () async {
      final local = createHistory('test:comic1', pageIndex: 10);
      final cloud = createHistory(
        'test:comic1',
        pageIndex: 20,
        updatedAt: local.updatedAt.add(const Duration(hours: 1)),
      );

      final data = buildPayload(histories: [cloud.toJson()]);
      await putAll(database, histories: [local]);

      await runMerge(database, data);

      final merged = (await database.histories.getAll()).single;
      expect(merged.pageIndex, 20);
    });

    test('merges folders by version vector when cloud dominates', () async {
      final local = createFolder('folderA', versionVector: {'device_local': 1});
      final cloud = createFolder('folderA', versionVector: {'device_cloud': 2});

      final data = buildPayload(folders: [cloud.toJson()]);
      await putAll(database, folders: [local]);

      await runMerge(database, data);

      final merged = (await database.folders.getAll()).single;
      expect(merged.syncId, cloud.syncId);
    });

    test('keeps local folder when local dominates', () async {
      final local = createFolder('folderA', versionVector: {'device_local': 2});
      final cloud = createFolder('folderA', versionVector: {'device_cloud': 1});

      final data = buildPayload(folders: [cloud.toJson()]);
      await putAll(database, folders: [local]);

      await runMerge(database, data);

      final merged = (await database.folders.getAll()).single;
      expect(merged.syncId, local.syncId);
    });

    test(
      'bumps version vector with the local device id in merge isolate',
      () async {
        final local = createFolder(
          'folderA',
          versionVector: {'device_local': 1},
          updatedAt: 1000,
        );
        final cloud = createFolder(
          'folderA',
          versionVector: {'device_cloud': 1},
          updatedAt: 2000,
        );

        final data = buildPayload(folders: [cloud.toJson()]);
        await putAll(database, folders: [local]);

        await runMerge(database, data);

        final merged = (await database.folders.getAll()).single;
        final vector =
            jsonDecode(merged.versionVectorJson) as Map<String, dynamic>;
        // 冲突合并后按本机 ID 提升；占位值 device_default 只应在未初始化时出现。
        expect(vector, {'device_local': 2, 'device_cloud': 1});
        expect(vector.containsKey('device_default'), isFalse);
      },
    );

    test('resolves folder uniqueKey conflict with active winner', () async {
      // Two devices created a folder with same parent/name/type but different syncIds.
      final localFolder = createFolder(
        'conflict',
        syncId: 'sync_local',
        versionVector: {'device_local': 2},
      );
      localFolder.updatedAt = 2000;
      final cloudFolder = createFolder(
        'conflict',
        syncId: 'sync_cloud',
        versionVector: {'device_cloud': 1},
      );
      cloudFolder.updatedAt = 1000;
      final child = createFolder(
        'child',
        syncId: 'child_sync',
        parentSyncId: cloudFolder.syncId,
        versionVector: {'device_cloud': 1},
      );
      final link = createLink(
        'test:comic1',
        folderSyncId: cloudFolder.syncId,
        versionVector: {'device_cloud': 1},
      );

      final data = buildPayload(
        folders: [cloudFolder.toJson(), child.toJson()],
        links: [link.toJson()],
      );
      await putAll(database, folders: [localFolder]);

      await runMerge(database, data);

      final folders = (await database.folders.getAll());
      final links = (await database.links.getAll());

      // Only one active folder remains for the uniqueKey.
      final activeFolders = folders.where((f) => f.deletedAt == null).toList();
      expect(activeFolders.length, 2); // winner + child
      final winner = activeFolders.firstWhere((f) => f.name == 'conflict');
      expect(winner.syncId, localFolder.syncId);

      // Child's parent should be migrated to winner.
      final storedChild = activeFolders.firstWhere((f) => f.name == 'child');
      expect(storedChild.parentSyncId, winner.syncId);

      // Link should point to winner.
      expect(links.single.folderSyncId, winner.syncId);
    });

    test('resolves folder uniqueKey conflict with tombstone winner', () async {
      final localFolder = createFolder(
        'conflict',
        syncId: 'sync_local',
        versionVector: {'device_local': 2},
        deletedAt: DateTime.now().toUtc().millisecondsSinceEpoch,
        updatedAt: 2000,
      );
      final cloudFolder = createFolder(
        'conflict',
        syncId: 'sync_cloud',
        versionVector: {'device_cloud': 1},
        updatedAt: 1000,
      );
      final cloudChild = createFolder(
        'child',
        syncId: 'child_sync',
        parentSyncId: cloudFolder.syncId,
        versionVector: {'device_cloud': 1},
      );
      final link = createLink(
        'test:comic1',
        folderSyncId: cloudFolder.syncId,
        versionVector: {'device_cloud': 1},
      );

      final data = buildPayload(
        folders: [cloudFolder.toJson(), cloudChild.toJson()],
        links: [link.toJson()],
      );
      await putAll(database, folders: [localFolder]);

      await runMerge(database, data);

      final folders = (await database.folders.getAll());
      final links = (await database.links.getAll());

      expect(folders.every((f) => f.deletedAt != null), isTrue);
      expect(links.single.deletedAt, isNotNull);
    });

    test('repairs orphan links by moving to root when folder syncId is missing', () async {
      // Cloud has a link pointing to a non-existent folder syncId.
      final link = createLink(
        'test:comic1',
        folderSyncId: 'missing_sync',
        versionVector: {'device_cloud': 1},
      );

      final data = buildPayload(links: [link.toJson()]);
      await runMerge(database, data);

      final folders = (await database.folders.getAll());
      final links = (await database.links.getAll());

      // No folders are created because the syncId cannot be resolved to a path.
      expect(folders, isEmpty);
      // The orphan link is repaired to point to the root folder.
      expect(links.single.deletedAt, isNull);
      expect(links.single.folderSyncId, isNull);
      expect(links.single.uniqueKey, 'test:comic1||favorite');
    });

    test('repairs orphan links by resurrecting tombstone folder when link dominates', () async {
      final folder = createFolder(
        'folderA',
        syncId: 'folder_sync',
        versionVector: {'device_local': 1},
        deletedAt: DateTime.now().toUtc().millisecondsSinceEpoch,
      );
      final link = createLink(
        'test:comic1',
        folderSyncId: 'folder_sync',
        versionVector: {'device_cloud': 2},
      );

      final data = buildPayload(links: [link.toJson()]);
      await putAll(database, folders: [folder]);

      await runMerge(database, data);

      final storedFolder = (await database.folders.getAll()).single;
      final storedLink = (await database.links.getAll()).single;
      expect(storedFolder.deletedAt, isNull);
      expect(storedLink.deletedAt, isNull);
      expect(storedLink.folderSyncId, storedFolder.syncId);
    });

    test('handles old path-based folder uniqueKey migration', () async {
      // Simulate old data: uniqueKey is "/parent/child|favorite" and no parentSyncId.
      final oldChild = ComicFolder(
        syncId: 'old_child',
        parentSyncId: null,
        uniqueKey: '/parent/child|favorite',
        name: 'child',
        typeData: ComicFolderType.favorite.name,
        versionVectorJson: '{"device_cloud": 1}',
        createdAt: 1,
        updatedAt: 1,
      );
      final oldParent = ComicFolder(
        syncId: 'old_parent',
        parentSyncId: null,
        uniqueKey: '/parent|favorite',
        name: 'parent',
        typeData: ComicFolderType.favorite.name,
        versionVectorJson: '{"device_cloud": 1}',
        createdAt: 1,
        updatedAt: 1,
      );

      final data = buildPayload(
        folders: [oldParent.toJson(), oldChild.toJson()],
      );
      await runMerge(database, data);

      final folders = (await database.folders.getAll());
      final parent = folders.firstWhere((f) => f.name == 'parent');
      final child = folders.firstWhere((f) => f.name == 'child');

      expect(child.parentSyncId, parent.syncId);
      expect(parent.uniqueKey, '|parent|favorite');
      expect(child.uniqueKey, '${parent.syncId}|child|favorite');
    });

    test('handles concurrent folder rename conflict', () async {
      // Both devices renamed the same original folder differently.
      final localFolder = createFolder(
        'renamed_local',
        syncId: 'sync_original',
        versionVector: {'device_local': 2, 'device_cloud': 1},
      );
      final cloudFolder = createFolder(
        'renamed_cloud',
        syncId: 'sync_original',
        versionVector: {'device_cloud': 1},
      );

      final data = buildPayload(folders: [cloudFolder.toJson()]);
      await putAll(database, folders: [localFolder]);

      await runMerge(database, data);

      final merged = (await database.folders.getAll()).single;
      // Local dominates by version vector.
      expect(merged.name, 'renamed_local');
      expect(merged.uniqueKey, '|renamed_local|favorite');
    });

    test('handles delete vs active conflict: delete dominates', () async {
      // Local deleted the folder; cloud created an active folder with same uniqueKey.
      final deletedFolder = createFolder(
        'folderA',
        syncId: 'sync_local',
        versionVector: {'device_local': 2, 'device_cloud': 1},
        deletedAt: 1000,
      );
      final cloudFolder = createFolder(
        'folderA',
        syncId: 'sync_cloud',
        versionVector: {'device_cloud': 1},
      );
      final cloudChild = createFolder(
        'child',
        syncId: 'sync_child',
        parentSyncId: cloudFolder.syncId,
        versionVector: {'device_cloud': 1},
      );

      final data = buildPayload(
        folders: [cloudFolder.toJson(), cloudChild.toJson()],
      );
      await putAll(database, folders: [deletedFolder]);

      await runMerge(database, data);

      final folders = (await database.folders.getAll());
      expect(folders.every((f) => f.deletedAt != null), isTrue);
    });

    test('handles equal version vectors by picking higher updatedAt', () async {
      final localFolder = createFolder(
        'folderA',
        syncId: 'sync_local',
        versionVector: {'device_local': 1, 'device_cloud': 1},
      );
      localFolder.updatedAt = 1000;
      final cloudFolder = createFolder(
        'folderA',
        syncId: 'sync_cloud',
        versionVector: {'device_local': 1, 'device_cloud': 1},
      );
      cloudFolder.updatedAt = 2000;

      final data = buildPayload(folders: [cloudFolder.toJson()]);
      await putAll(database, folders: [localFolder]);

      await runMerge(database, data);

      // 向量相等时按 updatedAt 更大的选，确保多端 converge。
      final merged = (await database.folders.getAll()).single;
      expect(merged.syncId, cloudFolder.syncId);
    });

    test(
      'handles equal version vectors and updatedAt by syncId tie-break',
      () async {
        final localFolder = createFolder(
          'folderA',
          syncId: 'sync_zzz',
          versionVector: {'device_local': 1, 'device_cloud': 1},
        );
        localFolder.updatedAt = 1000;
        final cloudFolder = createFolder(
          'folderA',
          syncId: 'sync_aaa',
          versionVector: {'device_local': 1, 'device_cloud': 1},
        );
        cloudFolder.updatedAt = 1000;

        final data = buildPayload(folders: [cloudFolder.toJson()]);
        await putAll(database, folders: [localFolder]);

        await runMerge(database, data);

        // updatedAt 也相同时按 syncId 字典序更大者胜出。
        final merged = (await database.folders.getAll()).single;
        expect(merged.syncId, localFolder.syncId);
      },
    );

    test('handles same comic added to same folder on two devices', () async {
      final folder = createFolder('folderA', syncId: 'sync_folder');
      final localLink = createLink(
        'test:comic1',
        folderSyncId: 'sync_folder',
        versionVector: {'device_local': 1},
      );
      final cloudLink = createLink(
        'test:comic1',
        folderSyncId: 'sync_folder',
        versionVector: {'device_cloud': 1},
      );

      final data = buildPayload(
        folders: [folder.toJson()],
        links: [cloudLink.toJson()],
      );
      await putAll(database, folders: [folder], links: [localLink]);

      await runMerge(database, data);

      final links = (await database.links.getAll());
      expect(links.length, 1);
      expect(links.single.deletedAt, isNull);
    });

    test('handles folder deleted and recreated with same name', () async {
      // Old folder was deleted; new folder with same name created.
      final oldFolder = createFolder(
        'sameName',
        syncId: 'sync_old',
        versionVector: {'device_local': 1},
        deletedAt: 1000,
      );
      oldFolder.updatedAt = 1000;
      final newFolder = createFolder(
        'sameName',
        syncId: 'sync_new',
        versionVector: {'device_cloud': 1},
      );

      final data = buildPayload(folders: [newFolder.toJson()]);
      await putAll(database, folders: [oldFolder]);

      await runMerge(database, data);

      final folders = (await database.folders.getAll());
      expect(folders.length, 1);
      expect(folders.single.deletedAt, isNull);
      expect(folders.single.syncId, newFolder.syncId);
    });

    test('handles old link uniqueKey with nested path migration', () async {
      // Old link uniqueKey format: comic|/parent/child|favorite
      final oldParent = ComicFolder(
        syncId: 'old_parent',
        parentSyncId: null,
        uniqueKey: '/parent|favorite',
        name: 'parent',
        typeData: ComicFolderType.favorite.name,
        versionVectorJson: '{"device_cloud": 1}',
        createdAt: 1,
        updatedAt: 1,
      );
      final oldChild = ComicFolder(
        syncId: 'old_child',
        parentSyncId: null,
        uniqueKey: '/parent/child|favorite',
        name: 'child',
        typeData: ComicFolderType.favorite.name,
        versionVectorJson: '{"device_cloud": 1}',
        createdAt: 1,
        updatedAt: 1,
      );
      final oldLink = ComicLink(
        uniqueKey: 'test:comic1|/parent/child|favorite',
        comicUniqueKey: 'test:comic1',
        folderSyncId: null,
        typeData: ComicFolderType.favorite.name,
        versionVectorJson: '{"device_cloud": 1}',
        createdAt: 1,
        updatedAt: 1,
      );

      final data = buildPayload(
        folders: [oldParent.toJson(), oldChild.toJson()],
        links: [oldLink.toJson()],
      );
      await runMerge(database, data);

      final folders = (await database.folders.getAll());
      final child = folders.firstWhere((f) => f.name == 'child');
      final link = (await database.links.getAll()).single;
      expect(link.folderSyncId, child.syncId);
      expect(link.uniqueKey, 'test:comic1|${child.syncId}|favorite');
    });

    test('handles mixed old and new folder/link data', () async {
      // New-style folder, old-style link without folderSyncId.
      final newFolder = createFolder('folderA', syncId: 'sync_folder');
      final oldLink = ComicLink(
        uniqueKey: 'test:comic1|/folderA|favorite',
        comicUniqueKey: 'test:comic1',
        folderSyncId: null,
        typeData: ComicFolderType.favorite.name,
        versionVectorJson: '{"device_cloud": 1}',
        createdAt: 1,
        updatedAt: 1,
      );

      final data = buildPayload(
        folders: [newFolder.toJson()],
        links: [oldLink.toJson()],
      );
      await runMerge(database, data);

      final link = (await database.links.getAll()).single;
      expect(link.folderSyncId, newFolder.syncId);
    });

    test('preserves local data when cloud is empty', () async {
      final localFolder = createFolder('folderA');
      final localFavorite = createFavorite('test:comic1');
      await putAll(
        database,
        folders: [localFolder],
        favorites: [localFavorite],
      );

      await runMerge(database, buildPayload());

      expect((await database.folders.getAll()).length, 1);
      expect((await database.favorites.getAll()).length, 1);
    });

    test('applies cloud data when local is empty', () async {
      final cloudFolder = createFolder('folderA');
      final cloudFavorite = createFavorite('test:comic1');

      final data = buildPayload(
        folders: [cloudFolder.toJson()],
        favorites: [cloudFavorite.toJson()],
      );
      await runMerge(database, data);

      expect((await database.folders.getAll()).length, 1);
      expect((await database.favorites.getAll()).length, 1);
    });

    test('handles large number of folders and links', () async {
      const count = 500;
      final folders = <ComicFolder>[];
      final links = <ComicLink>[];
      for (var i = 0; i < count; i++) {
        final folder = createFolder('folder$i', syncId: 'sync_folder_$i');
        folders.add(folder);
        links.add(createLink('test:comic$i', folderSyncId: folder.syncId));
      }

      final data = buildPayload(
        folders: folders.map((f) => f.toJson()).toList(),
        links: links.map((l) => l.toJson()).toList(),
      );
      await runMerge(database, data);

      expect((await database.folders.getAll()).length, count);
      expect((await database.links.getAll()).length, count);
    });
  });
}

// ==================== 测试工具函数 ====================

Map<String, dynamic> buildPayload({
  List<Map<String, dynamic>> favorites = const [],
  List<Map<String, dynamic>> histories = const [],
  List<Map<String, dynamic>> folders = const [],
  List<Map<String, dynamic>> links = const [],
}) {
  return {
    'version': 'v1',
    'favorites': favorites,
    'histories': histories,
    'folders': folders,
    'links': links,
  };
}

Future<void> putAll(
  Database database, {
  List<UnifiedComicFavorite> favorites = const [],
  List<UnifiedComicHistory> histories = const [],
  List<ComicFolder> folders = const [],
  List<ComicLink> links = const [],
}) async {
  await database.favorites.putMany(favorites);
  await database.histories.putMany(histories);
  await database.folders.putMany(folders);
  await database.links.putMany(links);
}

UnifiedComicFavorite createFavorite(
  String uniqueKey, {
  String title = 'Test',
  DateTime? updatedAt,
  bool deleted = false,
}) {
  final now = updatedAt ?? DateTime.now().toUtc();
  return UnifiedComicFavorite(
    uniqueKey: uniqueKey,
    source: 'test',
    comicId: uniqueKey,
    title: title,
    description: '',
    cover: '',
    creator: '',
    titleMeta: '',
    metadata: '',
    createdAt: now,
    updatedAt: now,
    deleted: deleted,
    schemaVersion: 1,
  );
}

UnifiedComicHistory createHistory(
  String uniqueKey, {
  int pageIndex = 0,
  DateTime? updatedAt,
}) {
  final now = updatedAt ?? DateTime.now().toUtc();
  return UnifiedComicHistory(
    uniqueKey: uniqueKey,
    source: 'test',
    comicId: uniqueKey,
    title: 'Test',
    description: '',
    cover: '',
    creator: '',
    titleMeta: '',
    metadata: '',
    chapterId: '',
    chapterTitle: '',
    chapterOrder: 0,
    pageIndex: pageIndex,
    createdAt: now,
    lastReadAt: now,
    updatedAt: now,
    deleted: false,
    schemaVersion: 1,
  );
}

ComicFolder createFolder(
  String name, {
  String? syncId,
  String? parentSyncId,
  Map<String, int>? versionVector,
  int? deletedAt,
  int? updatedAt,
}) {
  final now = DateTime.now().toUtc().millisecondsSinceEpoch;
  return ComicFolder(
    syncId: syncId ?? '${name}_sync',
    parentSyncId: parentSyncId,
    uniqueKey: '${parentSyncId ?? ''}|$name|favorite',
    name: name,
    typeData: ComicFolderType.favorite.name,
    versionVectorJson: versionVector != null
        ? jsonMap(versionVector)
        : '{"device_local": 1}',
    deletedAt: deletedAt,
    createdAt: now,
    updatedAt: updatedAt ?? now,
  );
}

ComicLink createLink(
  String comicUniqueKey, {
  required String folderSyncId,
  Map<String, int>? versionVector,
}) {
  final now = DateTime.now().toUtc().millisecondsSinceEpoch;
  return ComicLink(
    uniqueKey: '$comicUniqueKey|$folderSyncId|favorite',
    comicUniqueKey: comicUniqueKey,
    folderSyncId: folderSyncId,
    typeData: ComicFolderType.favorite.name,
    versionVectorJson: versionVector != null
        ? jsonMap(versionVector)
        : '{"device_local": 1}',
    createdAt: now,
    updatedAt: now,
  );
}

String jsonMap(Map<String, int> map) {
  final buffer = StringBuffer('{');
  var first = true;
  map.forEach((key, value) {
    if (!first) buffer.write(',');
    buffer.write('"$key":$value');
    first = false;
  });
  buffer.write('}');
  return buffer.toString();
}
