import 'dart:convert';

import 'package:zephyr/main.dart';
import 'package:zephyr/src/rust/api/database.dart' as rust;

/// 插件配置的 Dart 入口。
///
/// 合并、JSON 解析与持久化都在 Rust 侧完成；这里只负责取应用数据库句柄和
/// 把 UI 传入的 Dart 值编码成 JSON 文本。

/// 直接保存 JSON 文本（QJS 宿主路由使用同一套 Rust 实现）。
Future<String> savePluginConfigValueJson(
  String pluginName,
  String key,
  String valueJson,
) {
  return rust.dbPluginConfigSave(
    handle: database.db.handle,
    name: pluginName,
    key: key,
    value: valueJson,
  );
}

/// 读取配置，返回 `{"ok":true,"value":...}` JSON 文本。
Future<String> loadPluginConfigValueJson(
  String pluginName,
  String key,
  String fallbackJson,
) {
  return rust.dbPluginConfigLoad(
    handle: database.db.handle,
    name: pluginName,
    key: key,
    fallback: fallbackJson,
  );
}

/// 保存 Dart 值（内部编码成 JSON 文本后交给 Rust）。
Future<void> savePluginConfigValue(
  String pluginName,
  String key,
  dynamic value,
) async {
  await savePluginConfigValueJson(pluginName, key, jsonEncode(value));
}
