import 'package:flutter_test/flutter_test.dart';
import 'package:zephyr/main.dart';
import 'package:zephyr/plugin/local_comic_plugin.dart';
import 'package:zephyr/plugin/plugin_registry_service.dart';

import 'test_helper.dart';

void main() {
  setUpAll(() async {
    await TestDatabaseHelper.setUpTestDatabase();
  });

  tearDownAll(() async {
    await TestDatabaseHelper.tearDownTestDatabase();
  });

  setUp(() async {
    await database.plugins.removeAllInfos();
  });

  test('幽灵插件只安装一次并带 getInfo 缓存', () async {
    await ensureLocalComicPluginInstalled();
    await ensureLocalComicPluginInstalled();

    final rows = await database.plugins.listInfos();
    expect(rows, hasLength(1));
    final row = rows.single;
    expect(row.uuid, kLocalComicPluginId);
    expect(row.isEnabled, isTrue);
    expect(row.isDeleted, isFalse);
    expect(row.getInfoJson, contains(kLocalComicPluginName));
    expect(row.originScript, isEmpty);
    expect(
      await database.plugins.getScriptByUuid(kLocalComicPluginId),
      contains('module.exports'),
    );
  });

  test('幽灵插件被误删/禁用后会恢复', () async {
    await ensureLocalComicPluginInstalled();
    final row = (await database.plugins.listInfos()).single
      ..isDeleted = true
      ..isEnabled = false;
    await database.plugins.putInfo(row);

    await ensureLocalComicPluginInstalled();

    final restored = (await database.plugins.listInfos()).single;
    expect(restored.isDeleted, isFalse);
    expect(restored.isEnabled, isTrue);
  });

  test('幽灵插件不参与插件计数与排序，但 getInfo 可用', () async {
    await ensureLocalComicPluginInstalled();
    await PluginRegistryService.I.init();

    expect(
      PluginRegistryService.I.getCachedPluginInfo(kLocalComicPluginId)?['name'],
      kLocalComicPluginName,
    );
    expect(PluginRegistryService.I.isAnyPluginEnabled(), isFalse);
    expect(PluginRegistryService.I.getActivePluginCount(), 0);
    expect(PluginRegistryService.I.orderedPlugins(), isEmpty);

    final info = await PluginRegistryService.I.fetchPluginInfo(
      uuid: kLocalComicPluginId,
      runtimeName: kLocalComicPluginId,
    );
    expect(info['name'], kLocalComicPluginName);
    expect(
      PluginRegistryService.I.getCachedPluginInfo(kLocalComicPluginId)?['uuid'],
      kLocalComicPluginId,
    );
  });
}
