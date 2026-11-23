import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zephyr/main.dart';
import 'package:zephyr/page/setting/data_backup/backup_restore.dart';

import 'test_helper.dart';

void main() {
  setUpAll(TestDatabaseHelper.setUpTestDatabase);
  tearDownAll(TestDatabaseHelper.tearDownTestDatabase);

  test('备份 JSON 在 worker 池内恢复收藏并保留下载记录', () async {
    final favorite = createTestFavorite('test:restore');
    final download = createTestDownload('test:keep');
    await database.favorites.put(favorite);
    await database.downloads.put(download);

    final json = await database.collectAllDataJson(removeIds: true);
    final path = p.join(TestDatabaseHelper.tempPath, 'objectbox.json');
    await File(path).writeAsString(json);

    await database.favorites.removeAll();

    // includeDownloads=false：恢复备份里的收藏，同时保留本机下载记录。
    final restored = await importBackupData(
      RestoreBackupTask(
        handle: database.db.handle,
        dataJsonPath: path,
        includeDownloads: false,
      ),
    );

    expect(restored, isNotNull, reason: '备份里的 UserSetting 应恢复成功');
    final restoredFavorite = await database.favorites.getByKey('test:restore');
    expect(restoredFavorite?.title, favorite.title);
    expect(
      await database.downloads.getByKey('test:keep'),
      isNotNull,
      reason: '不含下载文件的备份不应清掉本机下载记录',
    );
  });
}
