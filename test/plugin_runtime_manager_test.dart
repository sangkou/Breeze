import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zephyr/plugin/plugin_runtime_manager.dart';
import 'package:zephyr/src/rust/qjs.dart';

class _InstallCall {
  const _InstallCall({
    required this.pluginId,
    required this.runtimeName,
    required this.revision,
  });

  final String pluginId;
  final String runtimeName;
  final String revision;
}

class _FakeBackend implements PluginRuntimeBackend {
  final Set<String> initialized = <String>{};
  final Map<String, String?> bundles = <String, String?>{};
  final Map<String, String> revisions = <String, String>{};
  final List<_InstallCall> installCalls = <_InstallCall>[];
  final List<String> initCalls = <String>[];
  final List<String> dropCalls = <String>[];

  Completer<void>? installGate;
  Completer<void>? initGate;
  Object? installError;
  Object? initError;
  bool dropResult = true;

  @override
  Future<String> readScriptRevision(String pluginId) async =>
      revisions[pluginId] ?? 'revision-1';

  @override
  Future<bool> isRuntimeInitialized(String runtimeName) async =>
      initialized.contains(runtimeName);

  @override
  Future<String?> currentBundleName(String runtimeName) async =>
      bundles[runtimeName];

  @override
  Future<QjsBundleInstallResult> install({
    required String pluginId,
    required String runtimeName,
    required bool pluginDebug,
    required String revision,
    required Future<String> Function() loadSource,
  }) async {
    installCalls.add(
      _InstallCall(
        pluginId: pluginId,
        runtimeName: runtimeName,
        revision: revision,
      ),
    );
    final gate = installGate;
    if (gate != null) {
      await gate.future;
    }
    final error = installError;
    if (error != null) {
      throw error;
    }
    initialized.add(runtimeName);
    bundles[runtimeName] = pluginId;
    return const QjsBundleInstallResult(usedBytecode: false);
  }

  @override
  Future<void> runInit({
    required String runtimeName,
    required String pluginId,
  }) async {
    initCalls.add(runtimeName);
    final gate = initGate;
    if (gate != null) {
      await gate.future;
    }
    final error = initError;
    if (error != null) {
      throw error;
    }
  }

  @override
  Future<bool> dropRuntime(String runtimeName) async {
    dropCalls.add(runtimeName);
    initialized.remove(runtimeName);
    bundles.remove(runtimeName);
    return dropResult;
  }
}

Future<void> _flush() => Future<void>.delayed(Duration.zero);

void main() {
  late _FakeBackend backend;
  late PluginRuntimeManager manager;

  setUp(() {
    backend = _FakeBackend();
    manager = PluginRuntimeManager(backend: backend);
  });

  Future<QjsBundleInstallResult> install({
    String pluginId = 'plugin-1',
    String runtimeName = 'runtime-1',
    bool pluginDebug = false,
  }) {
    return manager.install(
      pluginId: pluginId,
      runtimeName: runtimeName,
      pluginDebug: pluginDebug,
      loadSource: () async => 'module.exports = {};',
    );
  }

  test('同一 runtime + revision 的并发安装只执行一次', () async {
    backend.installGate = Completer<void>();
    final futures = List.generate(3, (_) => install());
    await _flush();

    expect(backend.installCalls, hasLength(1));

    backend.installGate!.complete();
    final results = await Future.wait(futures);
    expect(results, hasLength(3));
    expect(backend.installCalls, hasLength(1));
  });

  test('revision 变化时重新安装，不复用旧 in-flight', () async {
    backend.installGate = Completer<void>();
    backend.revisions['plugin-1'] = 'revision-1';
    final first = install();
    await _flush();

    backend.revisions['plugin-1'] = 'revision-2';
    final second = install();
    await _flush();

    expect(backend.installCalls, hasLength(2));
    expect(backend.installCalls[1].revision, 'revision-2');

    backend.installGate!.complete();
    await Future.wait([first, second]);
  });

  test('安装失败不留在 in-flight 表里，下次会重试', () async {
    backend.installError = StateError('install boom');

    await expectLater(install(), throwsA(isA<StateError>()));
    expect(backend.installCalls, hasLength(1));

    backend.installError = null;
    await install();
    expect(backend.installCalls, hasLength(2));
  });

  test('ensureReady：未初始化安装，已有 bundle 跳过，空 bundle 重装', () async {
    Future<bool> ensureReady() => manager.ensureReady(
      pluginId: 'plugin-1',
      runtimeName: 'runtime-1',
      pluginDebug: false,
      loadSource: () async => 'module.exports = {};',
    );

    expect(await ensureReady(), isTrue);
    expect(backend.installCalls, hasLength(1));

    expect(await ensureReady(), isFalse);
    expect(backend.installCalls, hasLength(1));

    backend.bundles['runtime-1'] = null;
    expect(await ensureReady(), isTrue);
    expect(backend.installCalls, hasLength(2));
  });

  test('并发 init 只执行一次，结果共享', () async {
    backend.initGate = Completer<void>();
    final first = manager.ensureInit(
      pluginId: 'plugin-1',
      runtimeName: 'runtime-1',
    );
    final second = manager.ensureInit(
      pluginId: 'plugin-1',
      runtimeName: 'runtime-1',
    );
    await _flush();

    expect(backend.initCalls, hasLength(1));

    backend.initGate!.complete();
    final outcomes = await Future.wait([first, second]);
    expect(outcomes.every((outcome) => outcome.success), isTrue);
    expect(backend.initCalls, hasLength(1));
  });

  test('init 成功后不再重复执行', () async {
    await manager.ensureInit(pluginId: 'plugin-1', runtimeName: 'runtime-1');
    await manager.ensureInit(pluginId: 'plugin-1', runtimeName: 'runtime-1');
    expect(backend.initCalls, hasLength(1));
  });

  test('init 失败不缓存，下一次调用重试', () async {
    backend.initError = StateError('init boom');
    final failed = await manager.ensureInit(
      pluginId: 'plugin-1',
      runtimeName: 'runtime-1',
    );
    expect(failed.success, isFalse);
    expect(failed.error, contains('init boom'));
    expect(backend.initCalls, hasLength(1));

    backend.initError = null;
    final retried = await manager.ensureInit(
      pluginId: 'plugin-1',
      runtimeName: 'runtime-1',
    );
    expect(retried.success, isTrue);
    expect(backend.initCalls, hasLength(2));
  });

  test('未实现 init 视为成功并缓存，不再重试', () async {
    backend.initError = StateError(
      'target is not function: init; targetType=undefined',
    );
    final outcome = await manager.ensureInit(
      pluginId: 'plugin-1',
      runtimeName: 'runtime-1',
    );
    expect(outcome.success, isTrue);
    expect(outcome.notImplemented, isTrue);

    backend.initError = null;
    await manager.ensureInit(pluginId: 'plugin-1', runtimeName: 'runtime-1');
    expect(backend.initCalls, hasLength(1));
  });

  test('安装新 bundle 后 init 记忆失效，需要重新执行', () async {
    await manager.ensureInit(pluginId: 'plugin-1', runtimeName: 'runtime-1');
    expect(backend.initCalls, hasLength(1));

    await install();
    await manager.ensureInit(pluginId: 'plugin-1', runtimeName: 'runtime-1');
    expect(backend.initCalls, hasLength(2));
  });

  test('安装期间完成的旧 init 不写入新 bundle 的记忆', () async {
    backend.initGate = Completer<void>();
    final stale = manager.ensureInit(
      pluginId: 'plugin-1',
      runtimeName: 'runtime-1',
    );
    await _flush();

    // 旧 init 还在跑时换 bundle：完成后的结果不能记到新 bundle 头上。
    await install();
    backend.initGate!.complete();
    expect((await stale).success, isTrue);

    await manager.ensureInit(pluginId: 'plugin-1', runtimeName: 'runtime-1');
    expect(backend.initCalls, hasLength(2));
  });

  test('dropIfPresent 清掉 runtime 与 init 记忆', () async {
    await install();
    await manager.ensureInit(pluginId: 'plugin-1', runtimeName: 'runtime-1');

    expect(await manager.dropIfPresent('runtime-1'), isTrue);
    expect(backend.dropCalls, hasLength(1));

    await manager.ensureInit(pluginId: 'plugin-1', runtimeName: 'runtime-1');
    expect(backend.initCalls, hasLength(2));

    expect(
      await manager.ensureReady(
        pluginId: 'plugin-1',
        runtimeName: 'runtime-1',
        pluginDebug: false,
        loadSource: () async => 'module.exports = {};',
      ),
      isTrue,
    );
    expect(backend.installCalls, hasLength(2));
  });

  test('dropIfPresent 对不存在的 runtime 不调用后端 drop', () async {
    expect(await manager.dropIfPresent('runtime-missing'), isFalse);
    expect(backend.dropCalls, isEmpty);
  });
}
