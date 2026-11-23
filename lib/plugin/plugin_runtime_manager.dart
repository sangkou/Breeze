import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:zephyr/main.dart';
import 'package:zephyr/plugin/plugin_runtime_loader.dart';
import 'package:zephyr/src/rust/api/qjs.dart';
import 'package:zephyr/src/rust/qjs.dart';

/// 一次插件 `init` 的结果。
class PluginInitOutcome {
  const PluginInitOutcome({
    required this.success,
    this.error = '',
    this.notImplemented = false,
  });

  final bool success;

  /// 失败原因（成功时为空）。
  final String error;

  /// 插件没有导出 `init`：按成功处理，但调用方可以据此跳过登录相关逻辑。
  final bool notImplemented;
}

/// runtime 生命周期的后端能力（默认走 Rust FFI；测试注入替身）。
abstract class PluginRuntimeBackend {
  Future<String> readScriptRevision(String pluginId);

  Future<bool> isRuntimeInitialized(String runtimeName);

  Future<String?> currentBundleName(String runtimeName);

  Future<QjsBundleInstallResult> install({
    required String pluginId,
    required String runtimeName,
    required bool pluginDebug,
    required String revision,
    required Future<String> Function() loadSource,
  });

  Future<void> runInit({required String runtimeName, required String pluginId});

  Future<bool> dropRuntime(String runtimeName);
}

String? _currentBundleFromJson(String raw) {
  final decoded = jsonDecode(raw);
  return decoded is String ? decoded : null;
}

/// 默认后端：Rust QJS runtime + SQLite 脚本 revision。
class FrbPluginRuntimeBackend implements PluginRuntimeBackend {
  const FrbPluginRuntimeBackend();

  @override
  Future<String> readScriptRevision(String pluginId) =>
      database.plugins.getScriptRevisionByUuid(pluginId);

  @override
  Future<bool> isRuntimeInitialized(String runtimeName) =>
      isQjsRuntimeInitialized(name: runtimeName);

  @override
  Future<String?> currentBundleName(String runtimeName) async {
    return _currentBundleFromJson(
      await qjsCurrentBundle(runtimeName: runtimeName),
    );
  }

  @override
  Future<QjsBundleInstallResult> install({
    required String pluginId,
    required String runtimeName,
    required bool pluginDebug,
    required String revision,
    required Future<String> Function() loadSource,
  }) {
    return installPluginRuntimeBundle(
      pluginId: pluginId,
      runtimeName: runtimeName,
      pluginDebug: pluginDebug,
      revision: revision,
      loadSource: loadSource,
    );
  }

  @override
  Future<void> runInit({
    required String runtimeName,
    required String pluginId,
  }) async {
    // init 只等跑完：直接拿原始字节丢弃，不解码不解析返回值，
    // void/undefined/空对象都算成功，只有抛错才算失败。
    await qjsTaskCall(
      runtimeName: runtimeName,
      source: pluginId,
      taskGroupKey: '',
      isOnce: false,
      fnPath: 'init',
      argsJson: '{}',
    );
  }

  @override
  Future<bool> dropRuntime(String runtimeName) =>
      qjsDropRuntime(runtimeName: runtimeName);
}

class _InitState {
  const _InitState({this.running, this.last});

  final Future<PluginInitOutcome>? running;
  final PluginInitOutcome? last;
}

String _errorText(Object error) {
  if (error is QjsCallFailure) {
    return error.message;
  }
  if (error is AnyhowException) {
    return error.message;
  }
  return error.toString();
}

/// 插件 runtime 生命周期（安装 / init / 释放）的唯一入口。
///
/// 去重规则：
/// - 安装按 runtime + 脚本 revision 单飞：首页/云收藏等页面同时首载同一个
///   插件时只编译一次；revision 变了才允许另一次安装；
/// - init 按 runtime 单飞，成功后记忆、失败不记忆（下一次调用重试）；
///   插件未导出 init 视为成功并记住；
/// - 安装成功或 runtime 被释放会清掉 init 记忆，保证换 bundle / 重建 runtime
///   后 init 会重新执行。
class PluginRuntimeManager {
  PluginRuntimeManager({PluginRuntimeBackend? backend})
    : _backend = backend ?? const FrbPluginRuntimeBackend();

  static PluginRuntimeManager I = PluginRuntimeManager();

  final PluginRuntimeBackend _backend;
  final Map<String, Future<QjsBundleInstallResult>> _installing = {};
  final Map<String, _InitState> _inits = {};
  final Map<String, int> _generations = {};

  @visibleForTesting
  void resetForTest() {
    _installing.clear();
    _inits.clear();
    _generations.clear();
  }

  /// 安装 bundle；同一 runtime + revision 的并发调用共享一次安装。
  Future<QjsBundleInstallResult> install({
    required String pluginId,
    required String runtimeName,
    required bool pluginDebug,
    required Future<String> Function() loadSource,
  }) async {
    final revision = await _backend.readScriptRevision(pluginId);
    final key =
        '$pluginId::$runtimeName::${pluginDebug ? 'debug' : 'release'}::$revision';
    final running = _installing[key];
    if (running != null) {
      return running;
    }

    final future = () async {
      final result = await _backend.install(
        pluginId: pluginId,
        runtimeName: runtimeName,
        pluginDebug: pluginDebug,
        revision: revision,
        loadSource: loadSource,
      );
      _invalidateInit(runtimeName);
      return result;
    }();
    _installing[key] = future;
    unawaited(
      future.then<void>(
        (_) => _clearInstall(key, future),
        onError: (Object _) => _clearInstall(key, future),
      ),
    );
    return future;
  }

  /// 页面调用路径：runtime 已初始化且有 bundle 就跳过，否则安装。
  ///
  /// 返回是否真的执行了安装。
  Future<bool> ensureReady({
    required String pluginId,
    required String runtimeName,
    required bool pluginDebug,
    required Future<String> Function() loadSource,
  }) async {
    var ready = await _backend.isRuntimeInitialized(runtimeName);
    if (ready) {
      String? currentBundle;
      try {
        currentBundle = await _backend.currentBundleName(runtimeName);
      } catch (e, st) {
        logger.e(e, stackTrace: st);
        currentBundle = null;
      }
      ready = currentBundle != null && currentBundle.trim().isNotEmpty;
    }
    if (ready) {
      return false;
    }
    await install(
      pluginId: pluginId,
      runtimeName: runtimeName,
      pluginDebug: pluginDebug,
      loadSource: loadSource,
    );
    return true;
  }

  /// 跑一次 `init`；同一 runtime 的并发调用共享同一个结果。
  ///
  /// 成功后同一 runtime 不再执行；失败不缓存，下一次调用重试。
  Future<PluginInitOutcome> ensureInit({
    required String pluginId,
    required String runtimeName,
  }) {
    final state = _inits[runtimeName];
    if (state != null) {
      final running = state.running;
      if (running != null) {
        return running;
      }
      final last = state.last;
      if (last != null && last.success) {
        return Future.value(last);
      }
    }

    final generation = _generations[runtimeName] ?? 0;
    final future = () async {
      PluginInitOutcome outcome;
      try {
        await _backend.runInit(runtimeName: runtimeName, pluginId: pluginId);
        outcome = const PluginInitOutcome(success: true);
      } catch (e) {
        final message = _errorText(e);
        if (message.contains('target is not function: init')) {
          outcome = const PluginInitOutcome(
            success: true,
            notImplemented: true,
          );
        } else {
          outcome = PluginInitOutcome(success: false, error: message);
        }
      }
      if ((_generations[runtimeName] ?? 0) == generation) {
        _inits[runtimeName] = _InitState(last: outcome);
      }
      return outcome;
    }();
    _inits[runtimeName] = _InitState(running: future);
    return future;
  }

  /// runtime 存在时释放它，并清掉安装/init 记忆。
  ///
  /// 不存在时直接返回 false，不调用后端 drop（与旧的“先查再删”行为一致）。
  Future<bool> dropIfPresent(String runtimeName) async {
    _invalidateInit(runtimeName);
    if (!await _backend.isRuntimeInitialized(runtimeName)) {
      return false;
    }
    return _backend.dropRuntime(runtimeName);
  }

  void _invalidateInit(String runtimeName) {
    _inits.remove(runtimeName);
    _generations[runtimeName] = (_generations[runtimeName] ?? 0) + 1;
  }

  void _clearInstall(String key, Future<QjsBundleInstallResult> future) {
    if (identical(_installing[key], future)) {
      _installing.remove(key);
    }
  }
}
