import 'package:flutter_test/flutter_test.dart';
import 'package:zephyr/main.dart';
import 'package:zephyr/network/sync/sync_service.dart';
import 'package:zephyr/object_box/model.dart';

import '../../test_helper.dart';

PluginInfo _plugin({
  required String uuid,
  required String version,
  required String script,
  required DateTime updatedAt,
  int scriptUpdatedAt = 0,
}) {
  return PluginInfo(
    uuid: uuid,
    version: version,
    originScript: script,
    scriptUpdatedAt: scriptUpdatedAt,
    insertedAt: DateTime.utc(2024, 1, 1),
    updatedAt: updatedAt,
    isEnabled: true,
    isDeleted: false,
    lastLoadSuccess: true,
    debug: false,
  );
}

void main() {
  setUpAll(TestDatabaseHelper.setUpTestDatabase);
  tearDownAll(TestDatabaseHelper.tearDownTestDatabase);
  tearDown(() async {
    await database.plugins.removeAllInfos();
    await database.plugins.removeAllConfigs();
  });

  test('插件同步块在 worker 池内组装并按脚本时间应用', () async {
    const uuid = 'test-plugin';
    final t1 = DateTime.utc(2024, 1, 2);
    final t2 = DateTime.utc(2024, 1, 3);
    await database.plugins.putInfoWithScript(
      _plugin(
        uuid: uuid,
        version: '1.0.0',
        script: 'local-script',
        updatedAt: t1,
      ),
    );

    // 上传负载：worker 查询带脚本的插件行并转成 JSON。
    final block = await buildPluginBlockDataInWorker(database.db.handle);
    final infos = block['pluginInfos'] as List<dynamic>;
    expect(infos, hasLength(1));
    expect((infos.single as Map)['originScript'], 'local-script');

    // 远端脚本更新：apply 必须换上远端脚本并报告 uuid 变化。
    final remote = _plugin(
      uuid: uuid,
      version: '2.0.0',
      script: 'remote-script',
      updatedAt: t2,
      scriptUpdatedAt: t2.millisecondsSinceEpoch,
    ).toJson()..remove('id');
    final result = await applyPluginBlockDataInWorker(
      PluginBlockApplyTask(
        handle: database.db.handle,
        pluginBlockData: <String, dynamic>{
          'pluginInfos': <dynamic>[remote],
          'pluginConfigs': <dynamic>[],
        },
      ),
    );

    expect(result.upsertedInfos, 1);
    expect(result.changedScriptUuids, <String>[uuid]);
    expect(await database.plugins.getScriptByUuid(uuid), 'remote-script');
    final stored = await database.plugins.getInfoByUuid(uuid);
    expect(stored?.version, '2.0.0');
  });
}
