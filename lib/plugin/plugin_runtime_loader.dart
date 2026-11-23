import 'dart:async';

import 'package:zephyr/main.dart';
import 'package:zephyr/plugin/plugin_bytecode_cache.dart';
import 'package:zephyr/src/rust/api/qjs.dart';
import 'package:zephyr/src/rust/qjs.dart';

/// 安装插件 runtime bundle：字节码可用时只传字节码，失败才加载源码。
///
/// 字节码文件名包含脚本 revision；revision 不匹配时 [PluginBytecodeCache.load]
/// 直接 miss，因此这里可以不带源码就信任字节码头（引擎/应用版本仍由 Rust 校验）。
///
/// [revision] 由调用方（[PluginRuntimeManager]）读取并作为安装去重的 key，
/// 这里不再重复查库，避免两处读到的 revision 不一致。
Future<QjsBundleInstallResult> installPluginRuntimeBundle({
  required String pluginId,
  required String runtimeName,
  required bool pluginDebug,
  required String revision,
  required Future<String> Function() loadSource,
}) async {
  final bytecode = await PluginBytecodeCache.instance.load(
    pluginId: pluginId,
    pluginDebug: pluginDebug,
    revision: revision,
  );

  Future<QjsBundleInstallResult> build(String bundleJs) {
    return buildQjsRuntime(
      request: QjsRuntimeBuildRequest(
        runtimeName: runtimeName,
        injectFilesystem: false,
        bundle: QjsRuntimeBundleBuild(
          bundleName: pluginId,
          bundleJs: bundleJs,
          bytecode: bytecode,
        ),
      ),
    );
  }

  if (bytecode != null) {
    try {
      final result = await build('');
      if (result.usedBytecode) {
        unawaited(
          PluginBytecodeCache.instance.afterLoad(
            pluginId: pluginId,
            bundleName: pluginId,
            source: '',
            pluginDebug: pluginDebug,
            revision: revision,
            result: result,
          ),
        );
        return result;
      }
    } catch (e, st) {
      logger.w('插件字节码加载失败，回退源码: $pluginId', error: e, stackTrace: st);
    }
  }

  final source = await loadSource();
  final result = await build(source);
  unawaited(
    PluginBytecodeCache.instance.afterLoad(
      pluginId: pluginId,
      bundleName: pluginId,
      source: source,
      pluginDebug: pluginDebug,
      revision: revision,
      result: result,
    ),
  );
  return result;
}
