import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zephyr/cubit/plugin_registry_cubit.dart';
import 'package:zephyr/main.dart';
import 'package:zephyr/object_box/model.dart';
import 'package:zephyr/page/discover/cubit/discover_cubit.dart';
import 'package:zephyr/plugin/plugin_registry_service.dart';

import 'test_helper.dart';

const _uuid = 'test-discover-no-init';

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
        getInfoJson: jsonEncode(<String, dynamic>{
          'uuid': _uuid,
          'name': 'Discover No Init Plugin',
          'version': '1.0.0',
          'iconUrl': '',
          'haveHome': false,
          'haveCloudFavorite': false,
          'functions': const <dynamic>[],
        }),
      ),
    );
    await PluginRegistryService.I.init();
  });

  tearDown(() async {
    await database.plugins.removeAllInfos();
  });

  test('发现页搜索源不依赖 init 成功', () async {
    final registry = PluginRegistryCubit();
    final discover = DiscoverCubit(registry: registry);

    try {
      expect(PluginRegistryService.I.isPluginInitOk(_uuid), isFalse);
      expect(discover.currentFrom, _uuid);
      expect(discover.state.infos[_uuid]?['name'], 'Discover No Init Plugin');
    } finally {
      await discover.close();
      await registry.close();
    }
  });
}
