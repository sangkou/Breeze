import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zephyr/cubit/plugin_registry_cubit.dart';
import 'package:zephyr/main.dart';
import 'package:zephyr/object_box/model.dart';
import 'package:zephyr/page/plugin_home/cubit/plugin_home_cubit.dart';
import 'package:zephyr/plugin/plugin_bytecode_cache.dart';
import 'package:zephyr/plugin/plugin_registry_service.dart';
import 'package:zephyr/src/rust/api/qjs.dart';

import 'test_helper.dart';

const _uuid = 'test-plugin-home-no-init';

const _initFailsScript = '''
const pages = () => ({
  data: {
    tabs: [
      {
        id: 'tab_1',
        title: 'Tab 1',
        page: {scheme: {type: 'page'}, data: {items: []}}
      }
    ]
  }
});

module.exports = {
  init: () => {
    throw new Error('init failed for test');
  },
  getPluginHomePagesBundle: pages,
  getPluginCloudFavoritePagesBundle: pages
};
''';

String _infoJson() {
  return jsonEncode(<String, dynamic>{
    'uuid': _uuid,
    'name': 'No Init Home Plugin',
    'version': '1.0.0',
    'iconUrl': '',
    'haveHome': true,
    'haveCloudFavorite': true,
    'functions': const <dynamic>[],
  });
}

Future<void> _useInitFailsScript() async {
  final row = (await database.plugins.getInfoByUuid(_uuid))!;
  row.originScript = _initFailsScript;
  await database.plugins.putInfoWithScript(row);
  await PluginRegistryService.I.init();
}

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
        originScript: '',
        insertedAt: now,
        updatedAt: now,
        isEnabled: true,
        isDeleted: false,
        lastLoadSuccess: false,
        debug: false,
        getInfoJson: _infoJson(),
      ),
    );
    await PluginRegistryService.I.init();
  });

  tearDown(() async {
    try {
      await qjsDropRuntime(runtimeName: _uuid);
    } catch (_) {}
    await PluginBytecodeCache.instance.delete(_uuid);
    await database.plugins.removeAllInfos();
  });

  test('首页选中插件后不等待 init 成功，搜索 source 已可用', () async {
    final registry = PluginRegistryCubit();
    final home = PluginHomeCubit(
      bundleFnPath: 'getPluginHomePagesBundle',
      capabilityFlag: 'haveHome',
      readMemory: () async => null,
      writeMemory: (_) async {},
      registry: registry,
    );

    try {
      expect(PluginRegistryService.I.isPluginInitOk(_uuid), isFalse);

      await home.load();

      expect(home.state.pluginId, _uuid);
      expect(home.state.error, isNotEmpty);
      expect(PluginRegistryService.I.isPluginInitOk(_uuid), isFalse);
    } finally {
      await home.close();
      await registry.close();
    }
  });

  test('init 抛错不影响首页 bundle 加载', () async {
    await _useInitFailsScript();

    final registry = PluginRegistryCubit();
    final home = PluginHomeCubit(
      bundleFnPath: 'getPluginHomePagesBundle',
      capabilityFlag: 'haveHome',
      readMemory: () async => null,
      writeMemory: (_) async {},
      registry: registry,
    );

    try {
      await home.load();

      expect(home.state.pluginId, _uuid);
      expect(home.state.error, isEmpty);
      expect(home.state.bundle, isNotNull);
      // init 失败不应阻塞 bundle，也不应把插件标记为已就绪。
      expect(PluginRegistryService.I.isPluginInitOk(_uuid), isFalse);
      // 等后台 init 的失败日志/清理跑完，避免测试结束后还动 runtime。
      await Future<void>.delayed(const Duration(milliseconds: 100));
    } finally {
      await home.close();
      await registry.close();
    }
  });

  test('init 抛错不影响云收藏页 bundle 加载', () async {
    await _useInitFailsScript();

    final registry = PluginRegistryCubit();
    final page = PluginHomeCubit(
      bundleFnPath: 'getPluginCloudFavoritePagesBundle',
      capabilityFlag: 'haveCloudFavorite',
      readMemory: () async => null,
      writeMemory: (_) async {},
      registry: registry,
    );

    try {
      await page.load();

      expect(page.state.pluginId, _uuid);
      expect(page.state.error, isEmpty);
      expect(page.state.bundle, isNotNull);
      expect(PluginRegistryService.I.isPluginInitOk(_uuid), isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    } finally {
      await page.close();
      await registry.close();
    }
  });
}
