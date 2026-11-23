import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:zephyr/main.dart';
import 'package:zephyr/src/rust/api/qjs.dart';
import 'package:zephyr/src/rust/api/simple.dart';
import 'package:zephyr/src/rust/qjs.dart';
import 'package:zephyr/util/storage/get_path.dart';
import 'package:zephyr/util/ohos/platform.dart';
import 'package:zephyr/util/ohos/file_bridge.dart';

/// 字节码缓存的宿主能力（默认走 Rust；测试可注入替身）。
abstract class PluginBytecodeBackend {
  /// 当前引擎的字节码格式版本（quickjs `BC_VERSION`）。
  int bytecodeVersion();

  /// 设置应用版本，参与缓存头校验。
  void setAppVersion(String version);

  /// 插件 id → 文件系统安全的 hash（`encodePath`）。
  String hashPluginId(String pluginId);

  /// 把插件源码编译成可落盘字节码（不执行）。
  Future<List<int>> compile({
    required String bundleName,
    required String source,
  });
}

class FrbPluginBytecodeBackend implements PluginBytecodeBackend {
  const FrbPluginBytecodeBackend();

  @override
  int bytecodeVersion() => qjsBytecodeVersion();

  @override
  void setAppVersion(String version) =>
      qjsSetBytecodeAppVersion(version: version);

  @override
  String hashPluginId(String pluginId) => encodePath(path: pluginId);

  @override
  Future<List<int>> compile({
    required String bundleName,
    required String source,
  }) => qjsCompileBundleBytecode(bundleName: bundleName, source: source);
}

/// 插件字节码缓存：`getFilePath()/plugin_bytecode/<字节码版本>_<id hash>.bc`。
///
/// - 文件名里的版本号是引擎 `BC_VERSION`（[PluginBytecodeBackend.bytecodeVersion]），
///   版本变了自然不命中旧文件；每次编译前会把同一插件其它版本的缓存删掉。
/// - 文件内容带宿主缓存头（引擎版本 / 应用版本 / 源码指纹），Rust 加载前校验，
///   任一不符立即回退源码加载，并由这里删除旧文件、后台重编译。
/// - 插件处于调试模式时不读也不写字节码，始终加载原始 JS。
class PluginBytecodeCache {
  PluginBytecodeCache({
    Future<String> Function()? directory,
    this.backend = const FrbPluginBytecodeBackend(),
  }) : _directory = directory ?? _defaultDirectory;

  static final PluginBytecodeCache instance = PluginBytecodeCache();

  static const String directoryName = 'plugin_bytecode';

  final Future<String> Function() _directory;
  final PluginBytecodeBackend backend;
  final Map<String, Future<void>> _inFlight = <String, Future<void>>{};
  Future<void>? _configuration;
  int? _bytecodeVersion;

  static Future<String> _defaultDirectory() async {
    return p.join(await getFilePath(), directoryName);
  }

  /// 读取该插件的字节码缓存；不存在、读取失败、插件调试模式或
  /// [revision] 为空时返回 null。
  Future<Uint8List?> load({
    required String pluginId,
    required bool pluginDebug,
    required String revision,
  }) async {
    if (pluginDebug || revision.trim().isEmpty) {
      return null;
    }
    try {
      await _ensureConfigured();
      final file = File(await _filePath(pluginId, revision));
      if (!await file.exists()) {
        return null;
      }
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) {
        await _deleteQuietly(file);
        return null;
      }
      return bytes;
    } catch (e, st) {
      logger.w('读取插件字节码缓存失败: $pluginId', error: e, stackTrace: st);
      return null;
    }
  }

  /// bundle 安装完成后的收尾：没走字节码就删除旧缓存并后台重编译。
  ///
  /// 调用方在 `buildQjsRuntime` 返回后调用；调试插件直接忽略。
  /// 返回的 future 在（可能的）后台编译结束后完成，调用方通常不 await。
  Future<void> afterLoad({
    required String pluginId,
    required String bundleName,
    required String source,
    required bool pluginDebug,
    required String revision,
    required QjsBundleInstallResult result,
  }) {
    if (pluginDebug || result.usedBytecode || revision.trim().isEmpty) {
      return Future<void>.value();
    }
    final bytecodeError = result.bytecodeError?.trim();
    if (bytecodeError != null && bytecodeError.isNotEmpty) {
      logger.d('[plugin-bytecode] $pluginId 缓存失效，回退源码: $bytecodeError');
    }
    return _scheduleCompile(
      pluginId: pluginId,
      bundleName: bundleName,
      source: source,
      revision: revision,
    );
  }

  /// 删除该插件的全部字节码缓存（插件被删除时调用）。
  Future<void> delete(String pluginId) async {
    try {
      await _sweep(pluginId: pluginId, keep: null);
    } catch (e, st) {
      logger.w('删除插件字节码缓存失败: $pluginId', error: e, stackTrace: st);
    }
  }

  Future<void> _ensureConfigured() {
    return _configuration ??= () async {
      var version = 'unknown';
      try {
        String appVersion;
        String build;
        if (isOhos) {
          final info = await getOhosPackageInfo();
          appVersion = info?.version ?? 'unknown';
          build = info?.buildNumber.trim() ?? '';
        } else {
          final info = await PackageInfo.fromPlatform();
          appVersion = info.version;
          build = info.buildNumber.trim();
        }
        version =
            '$appVersion${build.isEmpty ? '' : '+$build'}'
            '${kDebugMode ? '+debug' : ''}';
      } catch (e) {
        // 拿不到应用版本时用固定值：同一进程内编译与加载仍然一致。
        logger.d('[plugin-bytecode] 读取应用版本失败，使用兜底值', error: e);
      }
      backend.setAppVersion(version);
      _bytecodeVersion = backend.bytecodeVersion();
    }();
  }

  Future<String> _filePath(String pluginId, String revision) async {
    final directory = await _directory();
    return p.join(directory, _fileName(pluginId, revision));
  }

  String _fileName(String pluginId, String revision) {
    final version = _bytecodeVersion ?? backend.bytecodeVersion();
    return '${version}_${backend.hashPluginId(pluginId)}_$revision.bc';
  }

  Future<void> _scheduleCompile({
    required String pluginId,
    required String bundleName,
    required String source,
    required String revision,
  }) {
    final key = '$pluginId::$revision';
    final existing = _inFlight[key];
    if (existing != null) {
      return existing;
    }
    final future =
        _compileAndStore(
          pluginId: pluginId,
          bundleName: bundleName,
          source: source,
          revision: revision,
        ).whenComplete(() {
          // 注意：这里必须用块体。箭头函数会返回 `Map.remove` 的结果（正是当前
          // future 自身），whenComplete 会去 await 它，导致永远不完成。
          _inFlight.remove(key);
        });
    _inFlight[key] = future;
    return future;
  }

  Future<void> _compileAndStore({
    required String pluginId,
    required String bundleName,
    required String source,
    required String revision,
  }) async {
    if (source.trim().isEmpty || revision.trim().isEmpty) {
      return;
    }
    try {
      await _ensureConfigured();
      final directory = await _directory();
      // 首次使用时 `plugin_bytecode` 目录还不存在。Dart 的 writeAsBytes 不会
      // 递归创建父目录，缺了这一步缓存会静默写入失败（只留下一条 warning）。
      await Directory(directory).create(recursive: true);
      final target = File(p.join(directory, _fileName(pluginId, revision)));
      // 先清掉同一插件其它版本/残留缓存，再编译。
      await _sweep(pluginId: pluginId, keep: p.basename(target.path));

      final started = DateTime.now();
      final bytecode = await backend.compile(
        bundleName: bundleName,
        source: source,
      );
      if (bytecode.isEmpty) {
        return;
      }
      await _writeAtomically(target, bytecode);
      logger.d(
        '[plugin-bytecode] $pluginId 编译完成 '
        '(${bytecode.length} bytes, ${DateTime.now().difference(started).inMilliseconds}ms)',
      );
    } catch (e, st) {
      logger.w('编译插件字节码失败: $pluginId', error: e, stackTrace: st);
    }
  }

  /// 删除该插件除 [keep] 之外的字节码文件（含写入中断留下的 .tmp）。
  ///
  /// [keep] 为 null 时删除全部；不会碰其它插件（hash 不同）的文件。
  Future<void> _sweep({required String pluginId, required String? keep}) async {
    final directory = Directory(await _directory());
    if (!await directory.exists()) {
      return;
    }
    final hash = backend.hashPluginId(pluginId);
    final legacySuffix = '_$hash.bc';
    final revisionMarker = '_${hash}_';
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) {
        continue;
      }
      final name = p.basename(entity.path);
      if (keep != null && name == keep) {
        continue;
      }
      final isRevisioned =
          name.contains(revisionMarker) &&
          (name.endsWith('.bc') || name.endsWith('.bc.tmp'));
      if (!isRevisioned &&
          !name.endsWith(legacySuffix) &&
          !name.endsWith('$legacySuffix.tmp')) {
        continue;
      }
      await _deleteQuietly(entity);
    }
  }

  Future<void> _writeAtomically(File target, List<int> bytes) async {
    final temp = File('${target.path}.tmp');
    await temp.writeAsBytes(bytes, flush: true);
    if (await target.exists()) {
      await target.delete();
    }
    await temp.rename(target.path);
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      await file.delete();
    } catch (_) {
      // 缓存文件删不掉不影响功能，下次编译会再试。
    }
  }
}
