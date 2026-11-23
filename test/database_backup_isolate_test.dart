import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zephyr/main.dart';

import 'test_helper.dart';

void main() {
  setUpAll(TestDatabaseHelper.setUpTestDatabase);
  tearDownAll(TestDatabaseHelper.tearDownTestDatabase);
  tearDown(TestDatabaseHelper.cleanComicFolderBoxes);

  test('writeAllDataJsonFileAsync 在 worker 内写出全库 JSON', () async {
    await database.favorites.put(createTestFavorite('isolate_backup'));

    final path = p.join(TestDatabaseHelper.tempPath, 'backup.json');
    await database.writeAllDataJsonFileAsync(path);

    final map =
        jsonDecode(await File(path).readAsString()) as Map<String, dynamic>;
    final favorites = map['unifiedComicFavorite'] as List<dynamic>;
    expect(favorites, hasLength(1));
    expect(
      (favorites.single as Map<String, dynamic>)['uniqueKey'],
      'isolate_backup',
    );
  });
}
