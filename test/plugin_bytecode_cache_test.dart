import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zephyr/plugin/plugin_bytecode_cache.dart';
import 'package:zephyr/src/rust/qjs.dart';

class _FakeBackend implements PluginBytecodeBackend {
  _FakeBackend({this.publish = true});

  /// 编译是否产出字节码（false 用来模拟「编译失败/空结果」）。
  final bool publish;

  final List<({String bundleName, String source})> compiles =
      <({String bundleName, String source})>[];
  final List<String> appVersions = <String>[];

  @override
  int bytecodeVersion() => 26;

  @override
  void setAppVersion(String value) => appVersions.add(value);

  @override
  String hashPluginId(String pluginId) =>
      'f_${pluginId.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_')}';

  @override
  Future<List<int>> compile({
    required String bundleName,
    required String source,
  }) async {
    compiles.add((bundleName: bundleName, source: source));
    return publish ? <int>[1, 2, 3, 4] : <int>[];
  }
}

const _pluginA = '11111111-aaaa-bbbb-cccc-000000000001';
const _pluginB = '22222222-aaaa-bbbb-cccc-000000000002';
const _rev = 'rev1';
const _oldRev = 'rev0';

String _hash(String pluginId) =>
    'f_${pluginId.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_')}';

String _cacheFile(String pluginId, String revision) =>
    '26_${_hash(pluginId)}_$revision.bc';

void main() {
  late Directory tempDir;
  late _FakeBackend backend;

  PluginBytecodeCache buildCache() => PluginBytecodeCache(
    directory: () async => tempDir.path,
    backend: backend,
  );

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('plugin-bytecode-test');
    backend = _FakeBackend();
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('缺失缓存时返回 null 且不触发编译', () async {
    final cache = buildCache();
    final bytes = await cache.load(
      pluginId: _pluginA,
      pluginDebug: false,
      revision: _rev,
    );
    expect(bytes, isNull);
    expect(backend.compiles, isEmpty);
  });

  test('revision 不匹配时视为未命中', () async {
    final cache = buildCache();
    final oldFile = File(p.join(tempDir.path, _cacheFile(_pluginA, _oldRev)))
      ..writeAsBytesSync(<int>[9, 9, 9]);

    expect(
      await cache.load(pluginId: _pluginA, pluginDebug: false, revision: _rev),
      isNull,
    );
    expect(oldFile.existsSync(), isTrue);
  });

  test('调试插件既不读也不写字节码', () async {
    final cache = buildCache();
    final file = File(p.join(tempDir.path, _cacheFile(_pluginA, _rev)))
      ..writeAsBytesSync(<int>[9, 9, 9]);

    expect(
      await cache.load(pluginId: _pluginA, pluginDebug: true, revision: _rev),
      isNull,
    );

    await cache.afterLoad(
      pluginId: _pluginA,
      bundleName: _pluginA,
      source: 'module.exports = {};',
      pluginDebug: true,
      revision: _rev,
      result: const QjsBundleInstallResult(usedBytecode: false),
    );
    expect(backend.compiles, isEmpty);
    expect(file.existsSync(), isTrue);
  });

  test('字节码命中时不再编译', () async {
    final cache = buildCache();
    File(p.join(tempDir.path, _cacheFile(_pluginA, _rev)))
        .writeAsBytesSync(<int>[1, 2, 3]);

    expect(
      await cache.load(pluginId: _pluginA, pluginDebug: false, revision: _rev),
      <int>[1, 2, 3],
    );

    await cache.afterLoad(
      pluginId: _pluginA,
      bundleName: _pluginA,
      source: 'module.exports = {};',
      pluginDebug: false,
      revision: _rev,
      result: const QjsBundleInstallResult(usedBytecode: true),
    );
    expect(backend.compiles, isEmpty);
  });

  test('未命中时后台编译并以版本_hash_revision 落盘', () async {
    final cache = buildCache();
    await cache.afterLoad(
      pluginId: _pluginA,
      bundleName: _pluginA,
      source: 'module.exports = { value: 1 };',
      pluginDebug: false,
      revision: _rev,
      result: const QjsBundleInstallResult(
        usedBytecode: false,
        bytecodeError: 'bytecode-source-mismatch',
      ),
    );

    expect(backend.compiles, hasLength(1));
    expect(backend.compiles.single.bundleName, _pluginA);
    expect(backend.appVersions, isNotEmpty);

    final file = File(p.join(tempDir.path, _cacheFile(_pluginA, _rev)));
    expect(file.existsSync(), isTrue);
    expect(await file.readAsBytes(), <int>[1, 2, 3, 4]);
    expect(
      await cache.load(pluginId: _pluginA, pluginDebug: false, revision: _rev),
      <int>[1, 2, 3, 4],
    );
  });

  test('缓存目录不存在时自动创建并落盘', () async {
    // 生产路径 getFilePath()/plugin_bytecode 首次使用时并不存在。
    final nested = p.join(tempDir.path, PluginBytecodeCache.directoryName);
    expect(Directory(nested).existsSync(), isFalse);
    final cache = PluginBytecodeCache(
      directory: () async => nested,
      backend: backend,
    );

    await cache.afterLoad(
      pluginId: _pluginA,
      bundleName: _pluginA,
      source: 'module.exports = {};',
      pluginDebug: false,
      revision: _rev,
      result: const QjsBundleInstallResult(usedBytecode: false),
    );

    final file = File(p.join(nested, _cacheFile(_pluginA, _rev)));
    expect(file.existsSync(), isTrue);
    expect(
      await cache.load(pluginId: _pluginA, pluginDebug: false, revision: _rev),
      <int>[1, 2, 3, 4],
    );
  });

  test('编译前删除同插件其它版本/revision 的缓存，且不误删其它插件', () async {
    final cache = buildCache();
    final legacyA = File(p.join(tempDir.path, '25_${_hash(_pluginA)}.bc'))
      ..writeAsBytesSync(<int>[1]);
    final legacyATmp = File(
      p.join(tempDir.path, '25_${_hash(_pluginA)}.bc.tmp'),
    )..writeAsBytesSync(<int>[2]);
    final oldRevisionA = File(
      p.join(tempDir.path, _cacheFile(_pluginA, _oldRev)),
    )..writeAsBytesSync(<int>[3]);
    final otherPlugin = File(
      p.join(tempDir.path, _cacheFile(_pluginB, _oldRev)),
    )..writeAsBytesSync(<int>[4]);

    await cache.afterLoad(
      pluginId: _pluginA,
      bundleName: _pluginA,
      source: 'module.exports = {};',
      pluginDebug: false,
      revision: _rev,
      result: const QjsBundleInstallResult(usedBytecode: false),
    );

    expect(legacyA.existsSync(), isFalse);
    expect(legacyATmp.existsSync(), isFalse);
    expect(oldRevisionA.existsSync(), isFalse);
    expect(otherPlugin.existsSync(), isTrue);
    expect(
      File(p.join(tempDir.path, _cacheFile(_pluginA, _rev))).existsSync(),
      isTrue,
    );
  });

  test('空源码或空编译结果不落盘', () async {
    backend = _FakeBackend(publish: false);
    final cache = buildCache();

    await cache.afterLoad(
      pluginId: _pluginA,
      bundleName: _pluginA,
      source: '   ',
      pluginDebug: false,
      revision: _rev,
      result: const QjsBundleInstallResult(usedBytecode: false),
    );
    expect(backend.compiles, isEmpty);

    await cache.afterLoad(
      pluginId: _pluginA,
      bundleName: _pluginA,
      source: 'module.exports = {};',
      pluginDebug: false,
      revision: _rev,
      result: const QjsBundleInstallResult(usedBytecode: false),
    );
    expect(backend.compiles, hasLength(1));
    expect(
      Directory(tempDir.path).listSync().whereType<File>(),
      isEmpty,
      reason: '编译失败不应留下空文件或临时文件',
    );
  });

  test('删除插件缓存只清理该插件', () async {
    final cache = buildCache();
    final legacyA = File(p.join(tempDir.path, '25_${_hash(_pluginA)}.bc'))
      ..writeAsBytesSync(<int>[1]);
    final revisionA = File(p.join(tempDir.path, _cacheFile(_pluginA, _rev)))
      ..writeAsBytesSync(<int>[2]);
    final otherB = File(p.join(tempDir.path, _cacheFile(_pluginB, _rev)))
      ..writeAsBytesSync(<int>[3]);

    await cache.delete(_pluginA);

    expect(legacyA.existsSync(), isFalse);
    expect(revisionA.existsSync(), isFalse);
    expect(otherB.existsSync(), isTrue);
  });
}
