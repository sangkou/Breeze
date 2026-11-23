import 'package:flutter_test/flutter_test.dart';
import 'package:zephyr/main.dart';

import 'test_helper.dart';

void main() {
  setUpAll(TestDatabaseHelper.setUpTestDatabase);
  tearDownAll(TestDatabaseHelper.tearDownTestDatabase);
  tearDown(TestDatabaseHelper.cleanComicFolderBoxes);

  test('历史写入在 worker 池完成并回传自增 id', () async {
    final history = createTestHistory('test:pool');
    final firstId = await database.histories.putInWorker(history);

    expect(firstId, greaterThan(0));
    expect(await database.histories.count(), 1);

    // 阅读器把返回的 id 写回实体，下一次保存应更新同一行而不是再插一条。
    history
      ..id = firstId
      ..pageIndex = 7;
    final secondId = await database.histories.putInWorker(history);

    expect(secondId, firstId);
    expect(await database.histories.count(), 1);
    final stored = await database.histories.getByKey('test:pool');
    expect(stored?.pageIndex, 7);
  });
}
