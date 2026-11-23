import 'package:zephyr/config/global/global_setting.dart';
import 'package:zephyr/database/database.dart';
import 'package:zephyr/main.dart';

/// v11 -> v12：单本阅读偏好从 `readMode` 整列迁到 `overridesJson` 稀疏 patch。
Future<void> migrateV11ToV12(Database database) async {
  final all = await database.readPreferences.getAll();
  var migrated = 0;
  for (final item in all) {
    if (item.deleted) continue;
    final mode = item.readMode.clamp(0, 2);
    item.applyChanges(
      const ReadSettingState(),
      const ReadSettingState().copyWith(readMode: mode),
      includeKeys: const {'readMode'},
    );
    await database.readPreferences.put(item);
    migrated++;
  }
  logger.i('[migration_v11_to_v12] 已迁移 $migrated 条单本阅读偏好到 overridesJson');
}
