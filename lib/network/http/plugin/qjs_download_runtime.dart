import 'dart:async';
import 'dart:convert';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:zephyr/main.dart';
import 'package:zephyr/network/http/plugin/qjs_call_exception.dart';
import 'package:zephyr/plugin/plugin_registry_service.dart';
import 'package:zephyr/plugin/plugin_runtime_manager.dart';
import 'package:zephyr/service/download/download_cancel_signal.dart';
import 'package:zephyr/src/rust/api/qjs.dart';
import 'package:zephyr/src/rust/api/simple.dart';
import 'package:zephyr/type/pipe.dart';

final Map<String, Set<String>> _trackedRuntimesByGroup = {};

String _rawQjsErrorText(Object error) {
  if (error is QjsCallFailure) {
    return error.message;
  }
  if (error is AnyhowException) {
    return error.message;
  }
  return error.toString();
}

Future<T> _guardQjsCall<T>(
  Future<T> future, {
  required String fallbackSource,
}) async {
  try {
    return await future;
  } on DownloadTaskCancelledException {
    rethrow;
  } catch (error) {
    if (error is QjsCallException) {
      rethrow;
    }
    if (error is QjsCallFailure) {
      throw QjsCallException(
        source: error.source,
        message: error.message,
        cause: error,
      );
    }
    throw QjsCallException(
      source: fallbackSource,
      message: _rawQjsErrorText(error),
      cause: error,
    );
  }
}

String runtimeNameForPluginId(String pluginIdOrLegacy) {
  return normalizePluginId(pluginIdOrLegacy);
}

String normalizePluginId(String raw) {
  var value = raw.trim();
  while (value.length >= 2 && value.startsWith('(') && value.endsWith(')')) {
    value = value.substring(1, value.length - 1).trim();
  }
  return value;
}

String _buildTaskGroupId(String pluginId, String taskGroupKey) {
  return '$pluginId::$taskGroupKey';
}

void _trackRuntime({
  required String pluginId,
  required String taskGroupKey,
  required String runtimeName,
}) {
  (_trackedRuntimesByGroup[_buildTaskGroupId(pluginId, taskGroupKey)] ??=
          <String>{})
      .add(runtimeName);
}

void _untrackRuntime({
  required String pluginId,
  required String taskGroupKey,
  required String runtimeName,
}) {
  final groupId = _buildTaskGroupId(pluginId, taskGroupKey);
  final refs = _trackedRuntimesByGroup[groupId];
  refs?.remove(runtimeName);
  if (refs != null && refs.isEmpty) {
    _trackedRuntimesByGroup.remove(groupId);
  }
}

Future<void> ensureQjsRuntimeReady({required String pluginId}) async {
  final normalizedPluginId = (pluginId).trim();
  final runtimeName = runtimeNameForPluginId(normalizedPluginId);

  try {
    final pluginDebug =
        PluginRegistryService.I.getByUuid(normalizedPluginId)?.debug == true;
    await PluginRuntimeManager.I.ensureReady(
      pluginId: normalizedPluginId,
      runtimeName: runtimeName,
      pluginDebug: pluginDebug,
      loadSource: () => loadQjsBundleJs(normalizedPluginId),
    );
    // init 只做 URL 测速/登录预热，不应阻塞搜索、浏览等实际调用；
    // 失败只记录日志，去重与重试由 PluginRuntimeManager 负责。
    if (PluginRegistryService.I.isPluginInitOk(normalizedPluginId)) {
      return;
    }
    unawaited(
      _runRuntimeInitIfNeeded(
        pluginId: normalizedPluginId,
        runtimeName: runtimeName,
      ),
    );
  } catch (e) {
    logger.w('初始化 QJS 失败: $runtimeName', error: e);
    rethrow;
  }
}

/// 后台执行一次插件 init。失败只记录日志，不影响当前/后续实际调用。
///
/// 同一 runtime 的并发调用由 [PluginRuntimeManager.ensureInit] 合并；
/// 未实现 init 视为成功，不再输出失败日志。
Future<void> _runRuntimeInitIfNeeded({
  required String pluginId,
  required String runtimeName,
}) async {
  final outcome = await PluginRuntimeManager.I.ensureInit(
    pluginId: pluginId,
    runtimeName: runtimeName,
  );
  if (outcome.success) {
    return;
  }
  logger.w('插件 init 执行失败（不影响调用）: $runtimeName', error: outcome.error);
}

/// 统一执行插件 JS 任务,返回原始字节。
///
/// 内部按需走常驻 bundle(非 once)或一次性 debug 池(once,`bundleUrl`/`bundleJs` 二选一),
/// 并维护取消用的 runtime 跟踪。
Future<T> runQjsTask<T>({
  required String pluginId,
  required String fnPath,
  required String argsJson,
  String? runtimeName,
  String? taskGroupKey,
  required Future<T> Function({
    required String runtimeName,
    required String source,
    required String taskGroupKey,
    required bool isOnce,
    String? bundleJs,
    String? bundleUrl,
    required String fnPath,
    required String argsJson,
  })
  call,
}) async {
  if (taskGroupKey != null && taskGroupKey.isNotEmpty) {
    if (isDownloadCancelSignaled(taskGroupKey)) {
      throw const DownloadTaskCancelledException();
    }
  }

  final normalizedPluginId = (pluginId).trim();
  final resolvedRuntimeName =
      runtimeName ?? runtimeNameForPluginId(normalizedPluginId);
  final resolvedPluginId = normalizedPluginId.isNotEmpty
      ? normalizedPluginId
      : (resolvedRuntimeName).trim();
  if (resolvedPluginId.isEmpty) {
    throw StateError('pluginId/runtimeName 不能为空');
  }
  final resolvedFnPath = fnPath.trim();
  if (resolvedFnPath.isEmpty) {
    throw StateError('fnPath 不能为空: pluginId=$resolvedPluginId');
  }

  final useCallOnce = _shouldUseQjsCallOnce(resolvedPluginId);
  final debugBundleUrl = useCallOnce
      ? loadQjsDebugBundleUrl(resolvedPluginId)
      : null;
  final bundleJs = useCallOnce && debugBundleUrl == null
      ? await loadQjsBundleJs(resolvedPluginId)
      : null;

  if (!useCallOnce) {
    await ensureQjsRuntimeReady(pluginId: resolvedPluginId);
  }

  // QJS 结果通过 FRB 返回，避免 Dart 与 Rust 共享堆内存。
  final waitFuture = call(
    runtimeName: resolvedRuntimeName,
    source: resolvedPluginId,
    taskGroupKey: taskGroupKey ?? '',
    isOnce: useCallOnce,
    bundleJs: bundleJs,
    bundleUrl: debugBundleUrl,
    fnPath: resolvedFnPath,
    argsJson: argsJson,
  );
  final guardedFuture = _guardQjsCall(
    waitFuture,
    fallbackSource: resolvedPluginId,
  );

  var didUntrack = false;
  void untrackOnce() {
    if (didUntrack) return;
    didUntrack = true;
    if (taskGroupKey != null && taskGroupKey.isNotEmpty) {
      _untrackRuntime(
        pluginId: resolvedPluginId,
        taskGroupKey: taskGroupKey,
        runtimeName: resolvedRuntimeName,
      );
    }
  }

  if (taskGroupKey != null && taskGroupKey.isNotEmpty) {
    _trackRuntime(
      pluginId: resolvedPluginId,
      taskGroupKey: taskGroupKey,
      runtimeName: resolvedRuntimeName,
    );
  }

  unawaited(
    waitFuture.then<void>((_) {}).catchError((_) {}).whenComplete(untrackOnce),
  );
  // 注意：不要在 try/finally 里 return Future（会触发
  // unawaited_return_in_try_block）。untrack 已由上面的 whenComplete 在
  // future 完成时统一处理；空 taskGroupKey 时 untrackOnce 本身也是 no-op。
  return taskGroupKey != null && taskGroupKey.isNotEmpty
      ? raceWithDownloadCancel(taskGroupKey, guardedFuture)
      : guardedFuture;
}

/// 调用插件函数，返回 Rust 侧写入 source 的原始字节结果。
Future<QjsCallResult> executeQjsCall({
  required String pluginId,
  required String fnPath,
  required String argsJson,
  String? runtimeName,
  String? taskGroupKey,
}) {
  return runQjsTask<QjsCallResult>(
    pluginId: pluginId,
    fnPath: fnPath,
    argsJson: argsJson,
    runtimeName: runtimeName,
    taskGroupKey: taskGroupKey,
    call: qjsTaskCall,
  );
}

bool _shouldUseQjsCallOnce(String pluginId) {
  // return true;
  final normalized = normalizePluginId(pluginId);
  final state = PluginRegistryService.I.getByUuid(normalized);
  return state?.debug == true;
}

String? loadQjsDebugBundleUrl(String pluginId) {
  final normalizedPluginId = normalizePluginId(pluginId);
  if (normalizedPluginId.isEmpty) {
    throw StateError('pluginId 不能为空');
  }
  final runtimeState = PluginRegistryService.I.getByUuid(normalizedPluginId);
  if (runtimeState == null || runtimeState.isDeleted) {
    throw StateError('plugin_not_found:$normalizedPluginId');
  }
  if (!runtimeState.debug) {
    return null;
  }
  final bundleUrl = runtimeState.debugUrl?.trim() ?? '';
  return bundleUrl.isEmpty ? null : bundleUrl;
}

Future<void> cancelTrackedQjsTasks({
  required String pluginId,
  required String taskGroupKey,
}) async {
  final normalizedPluginId = (pluginId).trim();
  final groupId = _buildTaskGroupId(normalizedPluginId, taskGroupKey);
  final runtimeNames = _trackedRuntimesByGroup.remove(groupId)?.toList() ?? [];
  if (runtimeNames.isEmpty) {
    logger.d(
      '取消 QJS 任务组: $groupId -> no_tracked_tasks, fallback_runtime_cancel',
    );
    final fallbackRuntime = runtimeNameForPluginId(normalizedPluginId);
    if (fallbackRuntime.isNotEmpty) {
      runtimeNames.add(fallbackRuntime);
    }
  }

  var cancelledCount = 0;
  var notFoundCount = 0;
  final failedTaskIds = <String>[];

  await Future.wait(
    runtimeNames.map((runtimeName) async {
      try {
        final result = await qjsCancelTasksByGroup(
          runtimeName: runtimeName,
          taskGroupKey: taskGroupKey,
        );

        if (result.cancelled == 0 &&
            result.notFound == 0 &&
            result.failedRuntimeGroups.isEmpty) {
          notFoundCount += 1;
          logger.d('取消 QJS 任务组未找到: $runtimeName/$taskGroupKey');
          return;
        }

        final cancelled = result.cancelled;
        final notFound = result.notFound;
        cancelledCount += cancelled;
        notFoundCount += notFound;

        logger.d(
          '取消 QJS 任务组结果: $runtimeName/$taskGroupKey -> cancelled=$cancelled, not_found=$notFound',
        );

        if (result.failedRuntimeGroups.isNotEmpty) {
          failedTaskIds.addAll(
            result.failedRuntimeGroups.map(
              (group) => '$runtimeName/$taskGroupKey:$group',
            ),
          );
        }
      } catch (e) {
        failedTaskIds.add('$runtimeName/$taskGroupKey:${e.toString()}');
        logger.w('取消 QJS 任务组失败: $runtimeName/$taskGroupKey', error: e);
      }
    }),
  );

  logger.d(
    '取消 QJS 任务组结果: $groupId -> cancelled=$cancelledCount, not_found=$notFoundCount, failed=${failedTaskIds.length}',
  );

  if (failedTaskIds.isNotEmpty) {
    throw Exception('取消 QJS 任务组失败: ${failedTaskIds.join('; ')}');
  }
}

Future<String> loadQjsBundleJs(String pluginId) async {
  final normalizedPluginId = normalizePluginId(pluginId);
  if (normalizedPluginId.isEmpty) {
    throw StateError('pluginId 不能为空');
  }
  final runtimeState = PluginRegistryService.I.getByUuid(normalizedPluginId);
  if (runtimeState == null || runtimeState.isDeleted) {
    throw StateError('plugin_not_found:$normalizedPluginId');
  }

  String? dbBundle;
  Future<String> readDbBundle() async {
    return dbBundle ??= await database.plugins.getScriptByUuid(
      normalizedPluginId,
    );
  }

  if (!runtimeState.debug) {
    final bundle = await readDbBundle();
    if (bundle.trim().isNotEmpty) {
      return bundle;
    }
    throw StateError('bundle_js_missing_db:$normalizedPluginId');
  }

  final bundleUrl = runtimeState.debugUrl?.trim() ?? '';
  if (bundleUrl.isEmpty) {
    final bundle = await readDbBundle();
    if (bundle.trim().isNotEmpty) {
      return bundle;
    }
    throw StateError('bundle_js_missing_db:$normalizedPluginId');
  }

  try {
    if (bundleUrl.split(".").last == "br") {
      final response = await fetchDirect(bundleUrl);
      return await decompressExtreme(data: response.body).let(utf8.decode);
    } else {
      final response = await fetchDirect(bundleUrl);
      final body = response.text;
      if (body.trim().isNotEmpty) {
        return body;
      }
    }
    logger.w('debug bundle 为空，回退数据库: $bundleUrl');
  } catch (e) {
    logger.w('debug bundle 拉取失败，回退数据库: $bundleUrl', error: e);
  }
  final bundle = await readDbBundle();
  if (bundle.trim().isNotEmpty) {
    return bundle;
  }
  throw StateError('bundle_js不能为空: $normalizedPluginId');
}
