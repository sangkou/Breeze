import 'package:flutter_test/flutter_test.dart';
import 'package:zephyr/main.dart';
import 'package:zephyr/object_box/model.dart';

import 'test_helper.dart';

void main() {
  setUpAll(TestDatabaseHelper.setUpTestDatabase);
  tearDownAll(TestDatabaseHelper.tearDownTestDatabase);
  setUp(() async {
    await database.plugins.removeAllInfos();
  });

  test('默认查询不读脚本，元数据更新不会清空脚本', () async {
    final info = _buildInfo('script-test:a', script: 'console.log("a");');
    await database.plugins.putInfoWithScript(info);

    final listed = (await database.plugins.listInfos()).single;
    expect(listed.originScript, isEmpty);
    expect(listed.version, '1.0.0');

    final metadata = await database.plugins.getInfoByUuid('script-test:a');
    expect(metadata!.originScript, isEmpty);
    metadata.isEnabled = false;
    await database.plugins.putInfo(metadata);

    expect(
      await database.plugins.getScriptByUuid('script-test:a'),
      contains('console.log("a")'),
    );
  });

  test('显式 with-scripts 查询与写入会同步脚本表', () async {
    final info = _buildInfo('script-test:b', script: 'console.log("b");');
    await database.plugins.putInfoWithScript(info);

    final withScript = await database.plugins.getInfoWithScriptByUuid(
      'script-test:b',
    );
    expect(withScript!.originScript, contains('console.log("b")'));
    expect(
      withScript.scriptUpdatedAt,
      DateTime.utc(2026, 1, 1).millisecondsSinceEpoch,
    );
    final firstRevision = await database.plugins.getScriptRevisionByUuid(
      'script-test:b',
    );
    expect(firstRevision, isNotEmpty);

    withScript.originScript = 'console.log("b2");';
    withScript.scriptUpdatedAt = 2000;
    await database.plugins.putInfoWithScript(withScript);
    expect(
      await database.plugins.getScriptByUuid('script-test:b'),
      'console.log("b2");',
    );
    expect(
      (await database.plugins.getInfoWithScriptByUuid('script-test:b'))!
          .scriptUpdatedAt,
      2000,
    );
    final secondRevision = await database.plugins.getScriptRevisionByUuid(
      'script-test:b',
    );
    expect(secondRevision, isNotEmpty);
    expect(secondRevision, isNot(firstRevision));

    final all = await database.plugins.listInfosWithScripts();
    expect(all.single.originScript, 'console.log("b2");');

    // 内容相同的重写（同步/备份 apply）不应刷新 revision，
    // 否则每次同步都会把字节码缓存作废。
    withScript.originScript = 'console.log("b2");';
    withScript.scriptUpdatedAt = 9999;
    await database.plugins.putInfoWithScript(withScript);
    expect(
      await database.plugins.getScriptRevisionByUuid('script-test:b'),
      secondRevision,
    );
    expect(
      (await database.plugins.getInfoWithScriptByUuid('script-test:b'))!
          .scriptUpdatedAt,
      2000,
    );
  });

  test('删除元数据或写入空脚本会清理脚本行', () async {
    final first = _buildInfo('script-test:c', script: 'c');
    final second = _buildInfo('script-test:d', script: 'd');
    await database.plugins.putInfosWithScripts([first, second]);

    await database.plugins.removeInfoById(first.id);
    expect(await database.plugins.getScriptByUuid('script-test:c'), isEmpty);

    await database.plugins.putScript('script-test:d', '');
    expect(await database.plugins.getScriptByUuid('script-test:d'), isEmpty);

    await database.plugins.removeAllInfos();
    expect(await database.plugins.listInfos(), isEmpty);
  });
}

PluginInfo _buildInfo(String uuid, {required String script}) {
  final now = DateTime.utc(2026, 1, 1);
  return PluginInfo(
    uuid: uuid,
    version: '1.0.0',
    originScript: script,
    insertedAt: now,
    updatedAt: now,
    isEnabled: true,
    isDeleted: false,
    lastLoadSuccess: false,
    debug: false,
  );
}
