import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zephyr/main.dart';
import 'package:zephyr/object_box/model.dart';
import 'package:zephyr/plugin/plugin_bytecode_cache.dart';
import 'package:zephyr/plugin/plugin_registry_service.dart';
import 'package:zephyr/src/rust/api/qjs.dart';

import 'test_helper.dart';

const _hydratedUuid = 'test-info-db-hydrated';
const _deletedUuid = 'test-info-db-deleted';
const _missingUuid = 'test-info-db-missing';
const _missingRuntime = 'plugin_info_test_info_db_missing';

const _hydratedScript =
    '''
module.exports = {
  getInfo: () => ({
    uuid: '$_hydratedUuid',
    name: 'Script Must Not Run At Startup',
    version: '1.0.0',
    iconUrl: '',
    haveHome: false,
    haveCloudFavorite: false,
    functions: []
  })
};
''';

const _missingScript =
    '''
module.exports = {
  getInfo: () => ({
    uuid: '$_missingUuid',
    name: 'DB Missing Info Plugin',
    version: '1.0.0',
    iconUrl: '',
    haveHome: false,
    haveCloudFavorite: false,
    functions: []
  })
};
''';

PluginInfo _buildInfo({
  required String uuid,
  required String script,
  required String getInfoJson,
  bool isDeleted = false,
}) {
  final now = DateTime.now().toUtc();
  return PluginInfo(
    uuid: uuid,
    version: '1.0.0',
    originScript: script,
    insertedAt: now,
    updatedAt: now,
    isEnabled: !isDeleted,
    isDeleted: isDeleted,
    deletedAt: isDeleted ? now : null,
    lastLoadSuccess: false,
    debug: false,
    getInfoJson: getInfoJson,
  );
}

String _infoJson(String uuid, String name) {
  return jsonEncode(<String, dynamic>{
    'uuid': uuid,
    'name': name,
    'version': '1.0.0',
    'iconUrl': '',
    'haveHome': false,
    'haveCloudFavorite': false,
    'functions': const <dynamic>[],
  });
}

void main() {
  setUpAll(TestDatabaseHelper.setUpTestDatabase);
  tearDownAll(TestDatabaseHelper.tearDownTestDatabase);

  setUp(() async {
    await database.plugins.removeAllInfos();
    try {
      await qjsDropRuntime(runtimeName: _missingRuntime);
    } catch (_) {}
    await PluginBytecodeCache.instance.delete(_missingUuid);
  });

  tearDown(() async {
    try {
      await qjsDropRuntime(runtimeName: _missingRuntime);
    } catch (_) {}
    await PluginBytecodeCache.instance.delete(_missingUuid);
    await database.plugins.removeAllInfos();
  });

  test('init 只从 DB 水合 getInfo，不执行插件脚本', () async {
    await database.plugins.putInfoWithScript(
      _buildInfo(
        uuid: _hydratedUuid,
        script: _hydratedScript,
        getInfoJson: _infoJson(_hydratedUuid, 'DB Hydrated Plugin'),
      ),
    );
    await database.plugins.putInfoWithScript(
      _buildInfo(
        uuid: _deletedUuid,
        script: '',
        getInfoJson: _infoJson(_deletedUuid, 'Deleted Plugin'),
        isDeleted: true,
      ),
    );

    await PluginRegistryService.I.init();

    final infos = PluginRegistryService.I.infoSnapshot;
    expect(infos[_hydratedUuid]?['name'], 'DB Hydrated Plugin');
    expect(
      PluginRegistryService.I.getCachedPluginInfo(_hydratedUuid)?['name'],
      'DB Hydrated Plugin',
    );
    expect(infos.containsKey(_deletedUuid), isFalse);
  });

  test('禁用插件保留 DB 水合的 getInfo，不执行脚本', () async {
    await database.plugins.putInfoWithScript(
      _buildInfo(
        uuid: _hydratedUuid,
        script: _hydratedScript,
        getInfoJson: _infoJson(_hydratedUuid, 'DB Hydrated Plugin'),
      ),
    );
    await PluginRegistryService.I.init();

    await PluginRegistryService.I.setEnabled(_hydratedUuid, false);

    expect(
      PluginRegistryService.I.infoSnapshot[_hydratedUuid]?['name'],
      'DB Hydrated Plugin',
    );
    final row = await database.plugins.getInfoByUuid(_hydratedUuid);
    expect(row?.isEnabled, isFalse);
  });

  test('loadMissingPluginInfos 只补拉缺失的 getInfo 并持久化', () async {
    await database.plugins.putInfoWithScript(
      _buildInfo(
        uuid: _hydratedUuid,
        script: _hydratedScript,
        getInfoJson: _infoJson(_hydratedUuid, 'DB Hydrated Plugin'),
      ),
    );
    await database.plugins.putInfoWithScript(
      _buildInfo(uuid: _missingUuid, script: _missingScript, getInfoJson: ''),
    );

    await PluginRegistryService.I.init();
    expect(
      PluginRegistryService.I.infoSnapshot.containsKey(_missingUuid),
      isFalse,
    );
    expect(
      PluginRegistryService.I.infoSnapshot[_hydratedUuid]?['name'],
      'DB Hydrated Plugin',
    );

    await PluginRegistryService.I.loadMissingPluginInfos();

    expect(
      PluginRegistryService.I.infoSnapshot[_missingUuid]?['name'],
      'DB Missing Info Plugin',
    );
    // 已有 DB 缓存的插件不应被重新执行 getInfo。
    expect(
      PluginRegistryService.I.infoErrorSnapshot.containsKey(_hydratedUuid),
      isFalse,
    );
    final row = await database.plugins.getInfoByUuid(_missingUuid);
    expect(row?.getInfoJson, contains('DB Missing Info Plugin'));

    // 等后台字节码编译落盘后再删，避免测试结束后又写回缓存目录。
    final revision = await database.plugins.getScriptRevisionByUuid(
      _missingUuid,
    );
    for (var attempt = 0; attempt < 100; attempt++) {
      final cached = await PluginBytecodeCache.instance.load(
        pluginId: _missingUuid,
        pluginDebug: false,
        revision: revision,
      );
      if (cached != null) break;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    await PluginBytecodeCache.instance.delete(_missingUuid);
  });
}
