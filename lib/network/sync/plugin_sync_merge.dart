/// 插件同步的字段级合并。
///
/// 插件条目里混着两类状态：
/// - 脚本组：`version` / `originScript` / `scriptUpdatedAt` / `getInfoJson`；
/// - 元数据组：启停、排序、调试、加载结果、`updatedAt` 等。
///
/// 脚本组按 [pluginScriptUpdatedAtMs]（摘表前的旧负载回退到 `updatedAt`）
/// 单独 LWW，避免某台设备只是“加载得晚”刷新了 `updatedAt`，就把另一台
/// 设备更新的脚本/版本覆盖掉；元数据组仍按 `updatedAt` 整组 LWW。
library;

const Set<String> _scriptFields = <String>{
  'version',
  'originScript',
  'scriptUpdatedAt',
  'getInfoJson',
};

/// 插件元数据的新旧：与历史实现一致，取 `updatedAt` / `insertedAt` 较大者。
int pluginInfoUpdatedAtMs(Map<String, dynamic> item) {
  final updatedAt = _toMs(item['updatedAt']);
  final insertedAt = _toMs(item['insertedAt']);
  return updatedAt > insertedAt ? updatedAt : insertedAt;
}

/// 脚本的新旧。旧版同步负载没有 `scriptUpdatedAt`，回退到 `updatedAt`。
int pluginScriptUpdatedAtMs(Map<String, dynamic> item) {
  final explicit = _toMs(item['scriptUpdatedAt']);
  if (explicit > 0) {
    return explicit;
  }
  return _toMs(item['updatedAt']);
}

bool pluginInfoHasScript(Map<String, dynamic> item) {
  return (item['originScript']?.toString() ?? '').trim().isNotEmpty;
}

/// 给带脚本的条目补上显式的 `scriptUpdatedAt`；旧负载按 `updatedAt` 归一。
Map<String, dynamic> normalizePluginInfoEntry(Map<String, dynamic> item) {
  final out = Map<String, dynamic>.from(item);
  if (pluginInfoHasScript(out)) {
    if (_toMs(out['scriptUpdatedAt']) <= 0) {
      out['scriptUpdatedAt'] = pluginInfoUpdatedAtMs(out);
    }
  } else {
    out['scriptUpdatedAt'] = 0;
  }
  return out;
}

/// 按字段组合并同一 uuid 的插件条目。
///
/// [preferRemoteOnConflict] 只在两边时间戳完全相等时使用：同步 apply 传
/// `true`（保留“远端优先”的历史行为），上传前合并按块更新时间决定。
Map<String, dynamic> mergePluginInfoEntry(
  Map<String, dynamic> local,
  Map<String, dynamic> remote, {
  required bool preferRemoteOnConflict,
}) {
  final localHasScript = pluginInfoHasScript(local);
  final remoteHasScript = pluginInfoHasScript(remote);

  final bool useRemoteScript;
  if (localHasScript != remoteHasScript) {
    useRemoteScript = remoteHasScript;
  } else {
    final localScriptAt = pluginScriptUpdatedAtMs(local);
    final remoteScriptAt = pluginScriptUpdatedAtMs(remote);
    if (localScriptAt != remoteScriptAt) {
      useRemoteScript = remoteScriptAt > localScriptAt;
    } else {
      useRemoteScript = preferRemoteOnConflict;
    }
  }

  final localMetaAt = pluginInfoUpdatedAtMs(local);
  final remoteMetaAt = pluginInfoUpdatedAtMs(remote);
  final bool useRemoteMeta;
  if (localMetaAt != remoteMetaAt) {
    useRemoteMeta = remoteMetaAt > localMetaAt;
  } else {
    useRemoteMeta = preferRemoteOnConflict;
  }

  final merged = Map<String, dynamic>.from(useRemoteMeta ? remote : local);
  final scriptSource = useRemoteScript ? remote : local;
  for (final field in _scriptFields) {
    if (scriptSource.containsKey(field)) {
      merged[field] = scriptSource[field];
    } else {
      merged.remove(field);
    }
  }
  return normalizePluginInfoEntry(merged);
}

/// 同步 apply：远端优先，但保留本地可空的排序和 getInfo 缓存回退，
/// 与历史 apply 行为一致。
Map<String, dynamic> resolvePluginInfoForApply(
  Map<String, dynamic>? local,
  Map<String, dynamic> remote,
) {
  final resolved = local == null
      ? normalizePluginInfoEntry(remote)
      : mergePluginInfoEntry(local, remote, preferRemoteOnConflict: true);
  if (local != null) {
    // 与历史 apply 一致：本机安装时间不被远端元数据带走。
    resolved['insertedAt'] = local['insertedAt'];
    if (resolved['sortOrder'] == null && local['sortOrder'] != null) {
      resolved['sortOrder'] = local['sortOrder'];
    }
    if ((resolved['getInfoJson']?.toString() ?? '').isEmpty) {
      final localInfo = local['getInfoJson']?.toString() ?? '';
      if (localInfo.isNotEmpty) {
        resolved['getInfoJson'] = localInfo;
      }
    }
  }
  resolved['isDeleted'] = false;
  resolved['deletedAt'] = null;
  return resolved;
}

bool samePluginInfoJson(Map<String, dynamic> a, Map<String, dynamic> b) {
  if (a.length != b.length) {
    return false;
  }
  for (final entry in a.entries) {
    if (b[entry.key] != entry.value) {
      return false;
    }
  }
  return true;
}

/// 合并两个 `plugins` 同步块（`pluginInfos` + `pluginConfigs`）。
Map<String, dynamic> mergePluginBlockData(
  Map<String, dynamic> localData,
  Map<String, dynamic> remoteData, {
  required bool preferRemoteOnConflict,
}) {
  final mergedInfoByUuid = <String, Map<String, dynamic>>{};
  for (final item in _infos(localData)) {
    mergedInfoByUuid[item['uuid'] as String] = item;
  }
  for (final remote in _infos(remoteData)) {
    final uuid = remote['uuid'] as String;
    final local = mergedInfoByUuid[uuid];
    mergedInfoByUuid[uuid] = local == null
        ? normalizePluginInfoEntry(remote)
        : mergePluginInfoEntry(
            local,
            remote,
            preferRemoteOnConflict: preferRemoteOnConflict,
          );
  }

  final mergedConfigByName = <String, Map<String, dynamic>>{};
  for (final item in _configs(localData)) {
    final name = item['name']!.toString();
    mergedConfigByName[name] = item;
  }
  for (final item in _configs(remoteData)) {
    final name = item['name']!.toString();
    if (!mergedConfigByName.containsKey(name) || preferRemoteOnConflict) {
      mergedConfigByName[name] = item;
    }
  }

  final mergedInfos = mergedInfoByUuid.values.toList()
    ..sort((a, b) {
      final aKey = '${a['uuid'] ?? ''}:${a['version'] ?? ''}';
      final bKey = '${b['uuid'] ?? ''}:${b['version'] ?? ''}';
      return aKey.compareTo(bKey);
    });
  final mergedConfigs = mergedConfigByName.values.toList()
    ..sort((a, b) {
      final aName = a['name']?.toString() ?? '';
      final bName = b['name']?.toString() ?? '';
      return aName.compareTo(bName);
    });

  return <String, dynamic>{
    'pluginConfigs': mergedConfigs,
    'pluginInfos': mergedInfos,
  };
}

Iterable<Map<String, dynamic>> _infos(Map<String, dynamic> data) sync* {
  for (final item in _jsonMapList(data['pluginInfos'])) {
    final uuid = item['uuid']?.toString().trim() ?? '';
    if (uuid.isEmpty || item['isDeleted'] == true) {
      continue;
    }
    final next = Map<String, dynamic>.from(item)..['uuid'] = uuid;
    yield next;
  }
}

Iterable<Map<String, dynamic>> _configs(Map<String, dynamic> data) sync* {
  for (final item in _jsonMapList(data['pluginConfigs'])) {
    final name = item['name']?.toString().trim() ?? '';
    if (name.isEmpty) {
      continue;
    }
    yield Map<String, dynamic>.from(item)..['name'] = name;
  }
}

Iterable<Map<String, dynamic>> _jsonMapList(Object? raw) sync* {
  if (raw is! List) {
    return;
  }
  for (final item in raw) {
    if (item is Map) {
      yield Map<String, dynamic>.from(item);
    }
  }
}

int _toMs(Object? raw) {
  if (raw == null) {
    return 0;
  }
  if (raw is num) {
    return raw.toInt();
  }
  final text = raw.toString();
  final parsed = DateTime.tryParse(text);
  if (parsed != null) {
    return parsed.toUtc().millisecondsSinceEpoch;
  }
  return int.tryParse(text) ?? 0;
}
