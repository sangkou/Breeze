import 'package:flutter_test/flutter_test.dart';
import 'package:zephyr/network/sync/plugin_sync_merge.dart';

void main() {
  test('加载得晚不能覆盖更新的脚本，元数据仍按 updatedAt 合并', () {
    final local = _entry(
      version: '1.0.0',
      script: 'console.log("old");',
      scriptUpdatedAt: 1000,
      updatedAt: 3000,
      lastLoadSuccess: true,
      sortOrder: 1,
    );
    final remote = _entry(
      version: '2.0.0',
      script: 'console.log("new");',
      scriptUpdatedAt: 2000,
      updatedAt: 2000,
      lastLoadSuccess: false,
    );

    final merged = mergePluginInfoEntry(
      local,
      remote,
      preferRemoteOnConflict: false,
    );

    expect(merged['version'], '2.0.0');
    expect(merged['originScript'], 'console.log("new");');
    expect(merged['scriptUpdatedAt'], 2000);
    // 元数据来自本地（updatedAt 更新），但脚本来自远端。
    expect(merged['updatedAt'], _iso(3000));
    expect(merged['lastLoadSuccess'], isTrue);
    expect(merged['sortOrder'], 1);
  });

  test('apply 合并保护新脚本并保留本地排序', () {
    final local = _entry(
      version: '1.0.0',
      script: 'console.log("old");',
      scriptUpdatedAt: 1000,
      insertedAt: 500,
      updatedAt: 3000,
      sortOrder: 3,
    );
    final remote = _entry(
      version: '2.0.0',
      script: 'console.log("new");',
      scriptUpdatedAt: 2000,
      insertedAt: 100,
      updatedAt: 2000,
    );

    final resolved = resolvePluginInfoForApply(local, remote);

    expect(resolved['version'], '2.0.0');
    expect(resolved['originScript'], 'console.log("new");');
    expect(resolved['sortOrder'], 3);
    expect(resolved['updatedAt'], _iso(3000));
    expect(resolved['insertedAt'], _iso(500));
    expect(resolved['isDeleted'], isFalse);
    expect(resolved['deletedAt'], isNull);
  });

  test('远端只有元数据不会清空本地脚本', () {
    final local = _entry(
      version: '1.0.0',
      script: 'local-script',
      scriptUpdatedAt: 1000,
      updatedAt: 1000,
    );
    final remote = _entry(
      version: '1.0.0',
      script: '',
      scriptUpdatedAt: 0,
      updatedAt: 2000,
      lastLoadSuccess: true,
    );

    final merged = mergePluginInfoEntry(
      local,
      remote,
      preferRemoteOnConflict: false,
    );

    expect(merged['originScript'], 'local-script');
    expect(merged['version'], '1.0.0');
    expect(merged['scriptUpdatedAt'], 1000);
    expect(merged['updatedAt'], _iso(2000));
  });

  test('旧负载缺 scriptUpdatedAt 时回退到 updatedAt', () {
    final legacy = _entry(
      version: '1.0.0',
      script: 'legacy-script',
      updatedAt: 5000,
      includeScriptUpdatedAt: false,
    );

    expect(pluginScriptUpdatedAtMs(legacy), 5000);
    expect(normalizePluginInfoEntry(legacy)['scriptUpdatedAt'], 5000);
  });

  test('脚本时间完全相同时按 preferRemoteOnConflict 决定', () {
    final local = _entry(
      version: '1.0.0',
      script: 'local-script',
      scriptUpdatedAt: 1000,
      updatedAt: 1000,
    );
    final remote = _entry(
      version: '1.0.0',
      script: 'remote-script',
      scriptUpdatedAt: 1000,
      updatedAt: 1000,
    );

    expect(
      mergePluginInfoEntry(
        local,
        remote,
        preferRemoteOnConflict: true,
      )['originScript'],
      'remote-script',
    );
    expect(
      mergePluginInfoEntry(
        local,
        remote,
        preferRemoteOnConflict: false,
      )['originScript'],
      'local-script',
    );
  });

  test('块级合并不传播删除标记并按 uuid 字段合并', () {
    final localData = <String, dynamic>{
      'pluginInfos': <Map<String, dynamic>>[
        _entry(
          uuid: 'p1',
          version: '1.0.0',
          script: 'old',
          scriptUpdatedAt: 1000,
          updatedAt: 3000,
        ),
        _entry(uuid: 'deleted', version: '1.0.0', script: 'x', isDeleted: true),
      ],
      'pluginConfigs': <Map<String, dynamic>>[
        <String, dynamic>{'name': 'p1', 'config': '{"local":true}'},
      ],
    };
    final remoteData = <String, dynamic>{
      'pluginInfos': <Map<String, dynamic>>[
        _entry(
          uuid: 'p1',
          version: '2.0.0',
          script: 'new',
          scriptUpdatedAt: 2000,
          updatedAt: 2000,
        ),
      ],
      'pluginConfigs': <Map<String, dynamic>>[
        <String, dynamic>{'name': 'p1', 'config': '{"remote":true}'},
      ],
    };

    final merged = mergePluginBlockData(
      localData,
      remoteData,
      preferRemoteOnConflict: false,
    );
    final infos = (merged['pluginInfos'] as List).cast<Map<String, dynamic>>();
    expect(infos, hasLength(1));
    expect(infos.single['uuid'], 'p1');
    expect(infos.single['version'], '2.0.0');
    expect(infos.single['originScript'], 'new');
    expect((merged['pluginConfigs'] as List).single, <String, dynamic>{
      'name': 'p1',
      'config': '{"local":true}',
    });
  });
}

Map<String, dynamic> _entry({
  String uuid = 'plugin',
  required String version,
  required String script,
  int scriptUpdatedAt = 0,
  int updatedAt = 0,
  int insertedAt = 0,
  bool lastLoadSuccess = false,
  int? sortOrder,
  bool isDeleted = false,
  bool includeScriptUpdatedAt = true,
}) {
  return <String, dynamic>{
    'uuid': uuid,
    'version': version,
    'originScript': script,
    if (includeScriptUpdatedAt) 'scriptUpdatedAt': scriptUpdatedAt,
    'insertedAt': _iso(insertedAt),
    'updatedAt': _iso(updatedAt),
    'isEnabled': true,
    'isDeleted': isDeleted,
    'lastLoadSuccess': lastLoadSuccess,
    'sortOrder': sortOrder,
    'debug': false,
  };
}

String _iso(int milliseconds) => DateTime.fromMillisecondsSinceEpoch(
  milliseconds,
  isUtc: true,
).toIso8601String();
