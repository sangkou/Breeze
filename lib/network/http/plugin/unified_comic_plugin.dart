import 'dart:convert';

import 'package:zephyr/main.dart';
import 'package:zephyr/network/http/plugin/qjs_call_exception.dart';
import 'package:zephyr/network/http/plugin/qjs_download_runtime.dart';
import 'package:zephyr/network/http/plugin/unauthorized_payload.dart';
import 'package:zephyr/src/rust/api/qjs.dart';
import 'package:zephyr/util/event/event.dart';
import 'package:zephyr/util/json/json_value.dart';

/// 插件调用结果：`source` 是宿主调用时传入、由 Rust 原样带回的插件 id；
/// `data` 是插件返回体，宿主不修改其中的 source 字段。
class UnifiedPluginResult {
  const UnifiedPluginResult({required this.source, required this.data});

  final String source;
  final Map<String, dynamic> data;
}

Future<UnifiedPluginResult> callUnifiedComicPlugin({
  String? from,
  String? pluginId,
  required String fnPath,
  required Map<String, dynamic> core,
  Map<String, dynamic>? extern,
  String? runtimeName,
  // 新两页（插件首页/云收藏）传 true：登录错误由页面自己出
  // “登录/刷新”按钮，不走全局 NeedLogin 跳转。默认 false 保持现有行为。
  bool suppressNeedLoginEvent = false,
}) async {
  final resolvedFnPath = fnPath.trim();
  if (resolvedFnPath.isEmpty) {
    throw StateError('callUnifiedComicPlugin missing fnPath');
  }

  final resolvedPluginId = normalizePluginId(
    (pluginId?.trim().isNotEmpty ?? false) ? pluginId! : (from ?? ''),
  );
  if (resolvedPluginId.isEmpty) {
    throw StateError('callUnifiedComicPlugin missing valid plugin identity');
  }

  final payload = <String, dynamic>{...core, 'extern': extern ?? const {}};
  final argsJson = jsonEncode(payload);
  final runtime = runtimeName ?? resolvedPluginId;
  try {
    final result = await _invokeQjs(
      pluginId: resolvedPluginId,
      runtimeName: runtime,
      fnPath: resolvedFnPath,
      argsJson: argsJson,
    );
    final decoded = requireJsonMap(
      jsonDecode(utf8.decode(result.bytes, allowMalformed: true)),
      message: '插件返回格式错误',
    );
    return UnifiedPluginResult(source: result.source, data: decoded);
  } catch (error) {
    logger.d(error);
    final errorSource = error is QjsCallException
        ? error.source
        : resolvedPluginId;
    final unauthorized = parseUnauthorizedPayload(
      error,
      fallbackPluginId: errorSource,
    );
    if (unauthorized != null) {
      final loginPluginId = unauthorized.pluginId;
      if (!suppressNeedLoginEvent) {
        eventBus.fire(
          NeedLogin(from: loginPluginId, message: unauthorized.message),
        );
      }
      throw PluginUnauthorizedException(
        pluginId: loginPluginId,
        message: unauthorized.message,
      );
    }
    rethrow;
  }
}

Future<QjsCallResult> _invokeQjs({
  required String pluginId,
  required String runtimeName,
  required String fnPath,
  required String argsJson,
}) async {
  return executeQjsCall(
    pluginId: pluginId,
    runtimeName: runtimeName,
    fnPath: fnPath,
    argsJson: argsJson,
  );
}
