import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

/// OHOS [SharedPreferencesStorePlatform]，复用应用自己的系统通道。
///
/// 存储格式与旧 OHOS 插件兼容：key 原样写入，StringList 以
/// `jsonListPrefix` + JSON 保存。
class OhosSharedPreferences extends SharedPreferencesStorePlatform {
  static const MethodChannel _channel = MethodChannel('zephyr/ohos_file');
  static const String _defaultPrefix = 'flutter.';
  static const String _jsonListPrefix =
      'VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIGxpc3Qu!';
  static const String _platformListPrefix =
      'VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIGxpc3Qu';

  @override
  Future<bool> remove(String key) async {
    return await _channel.invokeMethod<bool>('prefs.remove', {'key': key}) ??
        false;
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    final Object nativeValue = valueType == 'StringList'
        ? '$_jsonListPrefix${jsonEncode(value)}'
        : value;
    return await _channel.invokeMethod<bool>('prefs.set', {
          'key': key,
          'type': valueType,
          'value': nativeValue,
        }) ??
        false;
  }

  @override
  Future<bool> clear() {
    return clearWithParameters(
      ClearParameters(filter: PreferencesFilter(prefix: _defaultPrefix)),
    );
  }

  @override
  Future<bool> clearWithPrefix(String prefix) {
    return clearWithParameters(
      ClearParameters(filter: PreferencesFilter(prefix: prefix)),
    );
  }

  @override
  Future<bool> clearWithParameters(ClearParameters parameters) async {
    final filter = parameters.filter;
    return await _channel.invokeMethod<bool>('prefs.clear', {
          'prefix': filter.prefix,
          'allowList': filter.allowList?.toList() ?? <String>[],
        }) ??
        false;
  }

  @override
  Future<Map<String, Object>> getAll() {
    return getAllWithParameters(
      GetAllParameters(filter: PreferencesFilter(prefix: _defaultPrefix)),
    );
  }

  @override
  Future<Map<String, Object>> getAllWithPrefix(String prefix) {
    return getAllWithParameters(
      GetAllParameters(filter: PreferencesFilter(prefix: prefix)),
    );
  }

  @override
  Future<Map<String, Object>> getAllWithParameters(
    GetAllParameters parameters,
  ) async {
    final filter = parameters.filter;
    final raw =
        await _channel.invokeMapMethod<String, Object>('prefs.getAll', {
          'prefix': filter.prefix,
          'allowList': filter.allowList?.toList() ?? <String>[],
        }) ??
        <String, Object>{};
    final result = <String, Object>{};
    for (final entry in raw.entries) {
      final value = entry.value;
      if (value is String && value.startsWith(_jsonListPrefix)) {
        result[entry.key] = (jsonDecode(
          value.substring(_jsonListPrefix.length),
        ) as List<dynamic>).cast<String>();
      } else if (value is String && value.startsWith(_platformListPrefix)) {
        result[entry.key] = (jsonDecode(
          value.substring(_platformListPrefix.length),
        ) as List<dynamic>).cast<String>();
      } else {
        result[entry.key] = value;
      }
    }
    return result;
  }
}
