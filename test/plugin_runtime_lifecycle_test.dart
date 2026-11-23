import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zephyr/main.dart';
import 'package:zephyr/object_box/model.dart';
import 'package:zephyr/plugin/plugin_bytecode_cache.dart';
import 'package:zephyr/plugin/plugin_registry_service.dart';
import 'package:zephyr/src/rust/api/qjs.dart';

import 'test_helper.dart';

const _successUuid = 'test-runtime-lifecycle-success';
const _noInitUuid = 'test-runtime-lifecycle-no-init';
const _failInitUuid = 'test-runtime-lifecycle-init-fail';
const _disableUuid = 'test-runtime-lifecycle-disable';

String _script(String uuid, {required bool withInit, bool initFails = false}) {
  return '''
let initCalls = 0;
const info = {
  uuid: '$uuid',
  name: 'Runtime Lifecycle $uuid',
  version: '1.0.0',
  iconUrl: '',
  haveHome: false,
  haveCloudFavorite: false,
  functions: []
};
module.exports = {
  ${withInit ? "init: () => { if ($initFails) { throw new Error('init failed for test'); } initCalls += 1; }," : ''}
  getInfo: () => info,
  getInitCalls: () => initCalls,
};
''';
}

Future<PluginRuntimeState> _putPlugin(String uuid, String script) async {
  final now = DateTime.now().toUtc();
  await database.plugins.putInfoWithScript(
    PluginInfo(
      uuid: uuid,
      version: '1.0.0',
      originScript: script,
      insertedAt: now,
      updatedAt: now,
      isEnabled: true,
      isDeleted: false,
      lastLoadSuccess: false,
      debug: false,
    ),
  );
  await PluginRegistryService.I.init();
  final state = PluginRegistryService.I.getByUuid(uuid);
  expect(state, isNotNull, reason: 'plugin state should be loaded: $uuid');
  return state!;
}

Future<void> _waitFor(
  Future<bool> Function() predicate, {
  required String reason,
}) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (await predicate()) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  fail('等待超时: $reason');
}

Future<int> _readInitCalls(String uuid) async {
  final result = await qjsTaskCall(
    runtimeName: uuid,
    source: uuid,
    taskGroupKey: '',
    isOnce: false,
    fnPath: 'getInitCalls',
    argsJson: '[]',
  );
  return jsonDecode(utf8.decode(result.bytes, allowMalformed: true)) as int;
}

Future<void> _dropRuntime(String uuid) async {
  try {
    await qjsDropRuntime(runtimeName: uuid);
  } catch (_) {}
  await PluginBytecodeCache.instance.delete(uuid);
}

void main() {
  setUpAll(TestDatabaseHelper.setUpTestDatabase);
  tearDownAll(TestDatabaseHelper.tearDownTestDatabase);

  const uuids = <String>[
    _successUuid,
    _noInitUuid,
    _failInitUuid,
    _disableUuid,
  ];

  setUp(() async {
    await database.plugins.removeAllInfos();
    for (final uuid in uuids) {
      await _dropRuntime(uuid);
    }
  });

  tearDown(() async {
    // 让后台 init / 字节码编译先跑完，避免测试结束后继续动 runtime。
    await Future<void>.delayed(const Duration(milliseconds: 100));
    for (final uuid in uuids) {
      await _dropRuntime(uuid);
    }
    await database.plugins.removeAllInfos();
  });

  test('安装 bundle 后 init 成功：标记 initOk、写库，且只跑一次', () async {
    final plugin = await _putPlugin(
      _successUuid,
      _script(_successUuid, withInit: true),
    );

    await PluginRegistryService.I.ensurePluginRuntimeReady(
      plugin,
      runtimeName: _successUuid,
    );
    expect(await isQjsRuntimeInitialized(name: _successUuid), isTrue);
    expect(
      jsonDecode(await qjsCurrentBundle(runtimeName: _successUuid)),
      _successUuid,
    );

    await PluginRegistryService.I.runPluginInitIfNeeded(
      plugin,
      runtimeName: _successUuid,
    );
    await _waitFor(
      () async =>
          PluginRegistryService.I.isPluginInitOk(_successUuid) &&
          (await database.plugins.getInfoByUuid(_successUuid))
                  ?.lastLoadSuccess ==
              true,
      reason: 'init 成功应标记 initOk 并写 lastLoadSuccess',
    );

    final row = await database.plugins.getInfoByUuid(_successUuid);
    expect(row?.lastLoadError, isNull);
    expect(await _readInitCalls(_successUuid), 1);

    // 已成功过：再次触发不应重跑 init（_pluginInitDone 短路）。
    await PluginRegistryService.I.runPluginInitIfNeeded(
      plugin,
      runtimeName: _successUuid,
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(await _readInitCalls(_successUuid), 1);
  });

  test('未实现 init：视为成功并标记 initOk，但不写 lastLoadSuccess', () async {
    final plugin = await _putPlugin(
      _noInitUuid,
      _script(_noInitUuid, withInit: false),
    );

    await PluginRegistryService.I.ensurePluginRuntimeReady(
      plugin,
      runtimeName: _noInitUuid,
    );
    await PluginRegistryService.I.runPluginInitIfNeeded(
      plugin,
      runtimeName: _noInitUuid,
    );
    await _waitFor(
      () async => PluginRegistryService.I.isPluginInitOk(_noInitUuid),
      reason: '未实现 init 应被标记为已完成',
    );

    final row = await database.plugins.getInfoByUuid(_noInitUuid);
    expect(row?.lastLoadSuccess, isFalse);
    expect(row?.lastLoadError, isNull);
  });

  test('init 抛错：不标记 initOk，写 lastLoadError', () async {
    final plugin = await _putPlugin(
      _failInitUuid,
      _script(_failInitUuid, withInit: true, initFails: true),
    );

    await PluginRegistryService.I.ensurePluginRuntimeReady(
      plugin,
      runtimeName: _failInitUuid,
    );
    await PluginRegistryService.I.runPluginInitIfNeeded(
      plugin,
      runtimeName: _failInitUuid,
    );
    await _waitFor(
      () async =>
          (await database.plugins.getInfoByUuid(_failInitUuid))
              ?.lastLoadError !=
          null,
      reason: 'init 失败应写 lastLoadError',
    );

    final row = await database.plugins.getInfoByUuid(_failInitUuid);
    expect(row?.lastLoadSuccess, isFalse);
    expect(row?.lastLoadError, contains('init 执行失败'));
    expect(PluginRegistryService.I.isPluginInitOk(_failInitUuid), isFalse);
  });

  test('禁用插件释放 runtime 并清掉 init 标记', () async {
    final plugin = await _putPlugin(
      _disableUuid,
      _script(_disableUuid, withInit: true),
    );

    await PluginRegistryService.I.ensurePluginRuntimeReady(
      plugin,
      runtimeName: _disableUuid,
    );
    await PluginRegistryService.I.runPluginInitIfNeeded(
      plugin,
      runtimeName: _disableUuid,
    );
    await _waitFor(
      () async => PluginRegistryService.I.isPluginInitOk(_disableUuid),
      reason: '禁用前 init 应先完成',
    );

    await PluginRegistryService.I.setEnabled(_disableUuid, false);

    expect(await isQjsRuntimeInitialized(name: _disableUuid), isFalse);
    expect(PluginRegistryService.I.isPluginInitOk(_disableUuid), isFalse);
  });
}
