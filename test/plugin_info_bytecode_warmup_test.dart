import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zephyr/main.dart';
import 'package:zephyr/object_box/model.dart';
import 'package:zephyr/plugin/plugin_bytecode_cache.dart';
import 'package:zephyr/plugin/plugin_registry_service.dart';
import 'package:zephyr/src/rust/api/qjs.dart';

import 'test_helper.dart';

const _uuid = 'test-info-bytecode-plugin';
const _infoRuntimeName = 'plugin_info_test_info_bytecode_plugin';
const _source =
    '''
module.exports = {
  getInfo: () => ({
    uuid: '$_uuid',
    name: 'Info Bytecode Plugin',
    version: '1.0.0',
    iconUrl: '',
    haveHome: false,
    haveCloudFavorite: false,
    functions: []
  })
};
''';

void main() {
  setUpAll(TestDatabaseHelper.setUpTestDatabase);
  tearDownAll(TestDatabaseHelper.tearDownTestDatabase);
  setUp(() async {
    await database.plugins.removeAllInfos();
    final now = DateTime.now().toUtc();
    await database.plugins.putInfoWithScript(
      PluginInfo(
        uuid: _uuid,
        version: '1.0.0',
        originScript: _source,
        insertedAt: now,
        updatedAt: now,
        isEnabled: true,
        isDeleted: false,
        lastLoadSuccess: false,
        debug: false,
      ),
    );
    await PluginRegistryService.I.init();
  });
  tearDown(() async {
    await PluginBytecodeCache.instance.delete(_uuid);
    try {
      await qjsDropRuntime(runtimeName: _infoRuntimeName);
    } catch (_) {}
    await database.plugins.removeAllInfos();
  });

  test('getInfo 预热第二次命中字节码，不再读取源码', () async {
    final first = await PluginRegistryService.I.fetchPluginInfo(
      uuid: _uuid,
      runtimeName: _uuid,
    );
    expect(first['name'], 'Info Bytecode Plugin');

    final revision = await database.plugins.getScriptRevisionByUuid(_uuid);
    expect(revision, isNotEmpty);

    Uint8List? cached;
    for (var attempt = 0; attempt < 100; attempt++) {
      cached = await PluginBytecodeCache.instance.load(
        pluginId: _uuid,
        pluginDebug: false,
        revision: revision,
      );
      if (cached != null) break;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(cached, isNotNull, reason: '首次 getInfo 后应后台编译出字节码');

    // 保留 revision，只把源码改成必然抛错；若第二次仍读源码会直接失败。
    await database.execute(
      'UPDATE "PluginScript" SET "originScript" = ? WHERE "uuid" = ?',
      <Object?>['throw new Error("source-read");', _uuid],
    );

    final second = await PluginRegistryService.I.fetchPluginInfo(
      uuid: _uuid,
      runtimeName: _uuid,
    );
    expect(second['name'], 'Info Bytecode Plugin');
  });
}
