import 'dart:convert';

import 'package:zephyr/database/database.dart';
import 'package:zephyr/main.dart';
import 'package:zephyr/object_box/model.dart';

/// v6 -> v7: 把 JSON 字段中残留的 `extension` 深度重命名为 `extern`。
Future<void> migrateV6ToV7(Database database) async {
  var favoriteChanged = 0;
  var historyChanged = 0;
  var downloadChanged = 0;

  final favorites = await database.favorites.getAll();
  final nextFavorites = <UnifiedComicFavorite>[];
  for (final item in favorites) {
    var changed = false;
    final newCover = _renameExtensionToExternDeep(item.cover);
    final newCreator = _renameExtensionToExternDeep(item.creator);
    final newTitleMeta = _renameExtensionToExternDeep(item.titleMeta);
    final newMetadata = _renameExtensionToExternDeep(item.metadata);
    if (newCover != null) {
      item.cover = newCover;
      changed = true;
    }
    if (newCreator != null) {
      item.creator = newCreator;
      changed = true;
    }
    if (newTitleMeta != null) {
      item.titleMeta = newTitleMeta;
      changed = true;
    }
    if (newMetadata != null) {
      item.metadata = newMetadata;
      changed = true;
    }
    if (changed) {
      nextFavorites.add(item);
      favoriteChanged++;
    }
  }
  await database.favorites.putMany(nextFavorites);

  final histories = await database.histories.getAll();
  final nextHistories = <UnifiedComicHistory>[];
  for (final item in histories) {
    var changed = false;
    final newCover = _renameExtensionToExternDeep(item.cover);
    final newCreator = _renameExtensionToExternDeep(item.creator);
    final newTitleMeta = _renameExtensionToExternDeep(item.titleMeta);
    final newMetadata = _renameExtensionToExternDeep(item.metadata);
    if (newCover != null) {
      item.cover = newCover;
      changed = true;
    }
    if (newCreator != null) {
      item.creator = newCreator;
      changed = true;
    }
    if (newTitleMeta != null) {
      item.titleMeta = newTitleMeta;
      changed = true;
    }
    if (newMetadata != null) {
      item.metadata = newMetadata;
      changed = true;
    }
    if (changed) {
      nextHistories.add(item);
      historyChanged++;
    }
  }
  await database.histories.putMany(nextHistories);

  final downloads = await database.downloads.getAll();
  final nextDownloads = <UnifiedComicDownload>[];
  for (final item in downloads) {
    var changed = false;
    final newCover = _renameExtensionToExternDeep(item.cover);
    final newCreator = _renameExtensionToExternDeep(item.creator);
    final newTitleMeta = _renameExtensionToExternDeep(item.titleMeta);
    final newMetadata = _renameExtensionToExternDeep(item.metadata);
    final newChapters = _renameExtensionToExternDeep(item.chapters);
    final newDetailJson = _renameExtensionToExternDeep(item.detailJson);
    if (newCover != null) {
      item.cover = newCover;
      changed = true;
    }
    if (newCreator != null) {
      item.creator = newCreator;
      changed = true;
    }
    if (newTitleMeta != null) {
      item.titleMeta = newTitleMeta;
      changed = true;
    }
    if (newMetadata != null) {
      item.metadata = newMetadata;
      changed = true;
    }
    if (newChapters != null) {
      item.chapters = newChapters;
      changed = true;
    }
    if (newDetailJson != null) {
      item.detailJson = newDetailJson;
      changed = true;
    }
    if (changed) {
      nextDownloads.add(item);
      downloadChanged++;
    }
  }
  await database.downloads.putMany(nextDownloads);

  logger.d(
    '[migration_v6_to_v7] '
    'favorite=$favoriteChanged, history=$historyChanged, download=$downloadChanged',
  );
}

String? _renameExtensionToExternDeep(String jsonStr) {
  if (!jsonStr.contains('"extension"')) return null;
  try {
    final decoded = jsonDecode(jsonStr);
    final result = _renameExtensionToExtern(decoded);
    if (!result.changed) return null;
    return jsonEncode(result.value);
  } catch (_) {
    return null;
  }
}

class _RenameResult {
  _RenameResult(this.value, this.changed);

  final dynamic value;
  final bool changed;
}

_RenameResult _renameExtensionToExtern(dynamic value) {
  if (value is Map<String, dynamic>) {
    var changed = false;
    final result = <String, dynamic>{};
    for (final entry in value.entries) {
      final newKey = entry.key == 'extension' ? 'extern' : entry.key;
      if (entry.key == 'extension') changed = true;
      final renamedValue = _renameExtensionToExtern(entry.value);
      if (renamedValue.changed) changed = true;
      result[newKey] = renamedValue.value;
    }
    return _RenameResult(result, changed);
  }
  if (value is List) {
    var changed = false;
    final result = <dynamic>[];
    for (final item in value) {
      final renamedItem = _renameExtensionToExtern(item);
      if (renamedItem.changed) changed = true;
      result.add(renamedItem.value);
    }
    return _RenameResult(result, changed);
  }
  if (value is String) {
    if (value.contains('"extension"')) {
      try {
        final decoded = jsonDecode(value);
        final renamed = _renameExtensionToExtern(decoded);
        if (renamed.changed) {
          return _RenameResult(jsonEncode(renamed.value), true);
        }
      } catch (_) {}
    }
    return _RenameResult(value, false);
  }
  return _RenameResult(value, false);
}
