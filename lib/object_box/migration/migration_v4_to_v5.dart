import 'dart:convert';

import 'package:zephyr/database/database.dart';
import 'package:zephyr/main.dart';
import 'package:zephyr/object_box/model.dart';

Future<void> migrateV4ToV5(Database database) async {
  final favorites = await database.favorites.getAll();
  final changedFavorites = <UnifiedComicFavorite>[];
  for (final item in favorites) {
    var changed = false;
    final newCover = _renameExtensionToExternInJsonString(item.cover);
    final newCreator = _renameExtensionToExternInJsonString(item.creator);
    final newTitleMeta = _renameExtensionToExternInJsonString(item.titleMeta);
    final newMetadata = _renameExtensionToExternInJsonString(item.metadata);
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
    if (changed) changedFavorites.add(item);
  }
  await database.favorites.putMany(changedFavorites);

  final histories = await database.histories.getAll();
  final changedHistories = <UnifiedComicHistory>[];
  for (final item in histories) {
    var changed = false;
    final newCover = _renameExtensionToExternInJsonString(item.cover);
    final newCreator = _renameExtensionToExternInJsonString(item.creator);
    final newTitleMeta = _renameExtensionToExternInJsonString(item.titleMeta);
    final newMetadata = _renameExtensionToExternInJsonString(item.metadata);
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
    if (changed) changedHistories.add(item);
  }
  await database.histories.putMany(changedHistories);

  final downloads = await database.downloads.getAll();
  final changedDownloads = <UnifiedComicDownload>[];
  for (final item in downloads) {
    var changed = false;
    final newCover = _renameExtensionToExternInJsonString(item.cover);
    final newCreator = _renameExtensionToExternInJsonString(item.creator);
    final newTitleMeta = _renameExtensionToExternInJsonString(item.titleMeta);
    final newMetadata = _renameExtensionToExternInJsonString(item.metadata);
    final newChapters = _renameExtensionToExternInJsonString(item.chapters);
    final newDetailJson = _renameExtensionToExternInJsonString(item.detailJson);
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
    if (changed) changedDownloads.add(item);
  }
  await database.downloads.putMany(changedDownloads);

  logger.d(
    '[migration_v4_to_v5] favorite=${changedFavorites.length}, '
    'history=${changedHistories.length}, download=${changedDownloads.length}',
  );
}

String? _renameExtensionToExternInJsonString(String jsonStr) {
  if (!jsonStr.contains('extension')) return null;
  final decoded = jsonDecode(jsonStr);
  final renamed = _renameExtensionToExtern(decoded);
  return jsonEncode(renamed);
}

dynamic _renameExtensionToExtern(dynamic value) {
  if (value is Map<String, dynamic>) {
    final result = <String, dynamic>{};
    for (final entry in value.entries) {
      result[entry.key == 'extension' ? 'extern' : entry.key] =
          _renameExtensionToExtern(entry.value);
    }
    return result;
  }
  if (value is List) {
    return value.map(_renameExtensionToExtern).toList();
  }
  return value;
}
