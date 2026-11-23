import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zephyr/database/plugin_config.dart';
import 'package:zephyr/main.dart';
import 'package:zephyr/object_box/model.dart';

import 'test_helper.dart';

/// 插件配置行为基线测试。
///
/// 迁移到 Rust 前后使用同一组断言，仅替换下面两个调用适配器：
/// - 迁移前：Dart bridge（onSavePluginConfig / onLoadPluginConfig）
/// - 迁移后：Rust FFI（dbPluginConfigSave / dbPluginConfigLoad）
Future<String> saveRaw(String name, String key, String value) =>
    savePluginConfigValueJson(name, key, value);

Future<String> loadRaw(String name, String key, String fallback) =>
    loadPluginConfigValueJson(name, key, fallback);

void main() {
  late String pluginName;

  setUp(() async {
    await TestDatabaseHelper.setUpTestDatabase();
    pluginName = 'plugin_cfg_${DateTime.now().microsecondsSinceEpoch}';
  });

  tearDown(TestDatabaseHelper.tearDownTestDatabase);

  Future<dynamic> load(String key, [String fallback = 'null']) async {
    final raw = await loadRaw(pluginName, key, fallback);
    final decoded = jsonDecode(raw);
    expect(decoded, isA<Map<String, dynamic>>());
    final envelope = decoded as Map<String, dynamic>;
    expect(envelope['ok'], isTrue);
    return envelope['value'];
  }

  Future<dynamic> loadOf(
    String name,
    String key, [
    String fallback = 'null',
  ]) async {
    final raw = await loadRaw(name, key, fallback);
    final envelope = jsonDecode(raw) as Map<String, dynamic>;
    expect(envelope['ok'], isTrue);
    return envelope['value'];
  }

  Future<Map<String, dynamic>> storedOf(String name) async {
    final row = await database.plugins.getConfigByName(name);
    expect(row, isNotNull);
    final decoded = jsonDecode(row!.config);
    expect(decoded, isA<Map<String, dynamic>>());
    return decoded as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> stored() => storedOf(pluginName);

  test(
    'missing config: whole object is empty and fallback is JSON-decoded',
    () async {
      expect(await load(''), <String, dynamic>{});
      expect(await load('theme', '"dark"'), 'dark');
      expect(await load('count', '12'), 12);
      expect(await load('ratio', '1.5'), 1.5);
      expect(await load('enabled', 'true'), isTrue);
      expect(await load('disabled', 'false'), isFalse);
      expect(await load('nothing', 'null'), isNull);
      expect(await load('plain', 'hello'), 'hello');
      expect(await load('empty', ''), '');
      expect(await database.plugins.getConfigByName(pluginName), isNull);
    },
  );

  test('save merges typed values and rewrites JSON compactly', () async {
    expect(await saveRaw(pluginName, 'theme', '"dark"'), '{"ok":true}');
    expect(
      await saveRaw(pluginName, 'meta', '{"a":1,"b":[true,null]}'),
      '{"ok":true}',
    );

    expect(await load('theme'), 'dark');
    expect(await load('meta'), <String, dynamic>{
      'a': 1,
      'b': <dynamic>[true, null],
    });
    expect(await load(''), <String, dynamic>{
      'theme': 'dark',
      'meta': <String, dynamic>{
        'a': 1,
        'b': <dynamic>[true, null],
      },
    });
    expect(await stored(), <String, dynamic>{
      'theme': 'dark',
      'meta': <String, dynamic>{
        'a': 1,
        'b': <dynamic>[true, null],
      },
    });

    final rows = (await database.plugins.listConfigs())
        .where((item) => item.name == pluginName)
        .toList();
    expect(rows, hasLength(1));
  });

  test('save overwrites existing keys and keeps unrelated keys', () async {
    await saveRaw(pluginName, 'theme', '"dark"');
    await saveRaw(pluginName, 'size', '12');
    await saveRaw(pluginName, 'theme', '"light"');
    await saveRaw(pluginName, 'extra', '{"x":[1,2]}');

    expect(await load('theme'), 'light');
    expect(await load('size'), 12);
    expect(await load('extra'), <String, dynamic>{
      'x': <dynamic>[1, 2],
    });
    expect(await stored(), <String, dynamic>{
      'theme': 'light',
      'size': 12,
      'extra': <String, dynamic>{
        'x': <dynamic>[1, 2],
      },
    });
  });

  test(
    'non-JSON and JSON-looking values are stored as their decoded form',
    () async {
      await saveRaw(pluginName, 'raw', 'not-json');
      await saveRaw(pluginName, 'spaced', '  x  ');
      await saveRaw(pluginName, 'blank', '   ');
      await saveRaw(pluginName, 'quoted', '"abc"');
      await saveRaw(pluginName, 'array', '["x",3,false]');
      await saveRaw(pluginName, 'nullValue', 'null');

      expect(await load('raw'), 'not-json');
      expect(await load('spaced'), '  x  ');
      expect(await load('blank'), '   ');
      expect(await load('quoted'), 'abc');
      expect(await load('array'), <dynamic>['x', 3, false]);
      expect(await load('nullValue'), isNull);
      expect(await load('missing', '"fallback"'), 'fallback');
    },
  );

  test(
    'empty key save creates an empty config row without changing data',
    () async {
      expect(await load(''), <String, dynamic>{});
      expect(await saveRaw(pluginName, '', '123'), '{"ok":true}');
      expect(await stored(), <String, dynamic>{});
      expect(await load(''), <String, dynamic>{});
    },
  );

  test('malformed existing config is treated as an empty object', () async {
    final broken = '${pluginName}_broken';
    await database.plugins.putConfig(
      PluginConfig(name: broken, config: 'not a json object'),
    );

    expect(await loadOf(broken, ''), <String, dynamic>{});
    expect(await loadOf(broken, 'k', '7'), 7);

    await saveRaw(broken, 'k', '7');
    expect(await storedOf(broken), <String, dynamic>{'k': 7});
  });

  test('savePluginConfigValue encodes Dart values before persisting', () async {
    await savePluginConfigValue(pluginName, 'number', 3.5);
    await savePluginConfigValue(pluginName, 'object', <String, dynamic>{
      'a': true,
      'b': null,
    });
    await savePluginConfigValue(pluginName, 'text', 'hello');

    expect(await load('number'), 3.5);
    expect(await load('object'), <String, dynamic>{'a': true, 'b': null});
    expect(await load('text'), 'hello');
  });

  test('load response envelope is stable', () async {
    await saveRaw(pluginName, 'k', '{"v":1}');
    final raw = await loadRaw(pluginName, 'k', 'null');
    expect(raw, '{"ok":true,"value":{"v":1}}');
    expect(
      await loadRaw(pluginName, '', 'null'),
      '{"ok":true,"value":{"k":{"v":1}}}',
    );
  });
}
