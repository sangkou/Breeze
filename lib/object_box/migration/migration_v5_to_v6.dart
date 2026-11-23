import 'dart:convert';

import 'package:zephyr/database/database.dart';
import 'package:zephyr/main.dart';
import 'package:zephyr/network/sync/sync_device_id.dart';
import 'package:zephyr/object_box/model.dart';

/// v5 -> v6: 为所有未删除的本地收藏/下载漫画补一条根目录 ComicLink。
Future<void> migrateV5ToV6(Database database) async {
  var migrated = 0;
  var skipped = 0;
  final now = DateTime.now().toUtc().millisecondsSinceEpoch;
  final deviceId = syncDeviceId;

  Future<void> ensureLink(String comicUniqueKey, ComicFolderType type) async {
    final linkKey = '$comicUniqueKey||${type.name}';
    final existing = await database.links.getByUniqueKey(linkKey);
    if (existing != null) {
      if (existing.deletedAt != null) {
        existing
          ..deletedAt = null
          ..createdAt = now
          ..updatedAt = now
          ..versionVectorJson = _bumpVersionVector(
            existing.versionVectorJson,
            deviceId,
          );
        await database.links.put(existing);
        migrated++;
      } else {
        skipped++;
      }
      return;
    }
    await database.links.put(
      ComicLink(
        uniqueKey: linkKey,
        comicUniqueKey: comicUniqueKey,
        typeData: type.name,
        versionVectorJson: jsonEncode(<String, int>{deviceId: 1}),
        createdAt: now,
        updatedAt: now,
      ),
    );
    migrated++;
  }

  for (final comic in await database.favorites.listActive()) {
    await ensureLink(comic.uniqueKey, ComicFolderType.favorite);
  }
  for (final comic in await database.downloads.listActive()) {
    await ensureLink(comic.uniqueKey, ComicFolderType.download);
  }

  logger.d('[migration_v5_to_v6] migrated=$migrated, skipped=$skipped');
}

String _bumpVersionVector(String raw, String deviceId) {
  final map = <String, int>{};
  if (raw.trim().isNotEmpty) {
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      for (final entry in decoded.entries) {
        map[entry.key] = (entry.value as num).toInt();
      }
    } catch (_) {}
  }
  map[deviceId] = (map[deviceId] ?? 0) + 1;
  return jsonEncode(map);
}
