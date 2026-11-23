import 'package:zephyr/config/global/color_theme_types.dart';
import 'package:zephyr/database/database.dart';
import 'package:zephyr/main.dart';

Future<void> migrateV3ToV4(Database database) async {
  final removed = await database.downloadTasks.removeAll();
  logger.d('[migration_v3_to_v4] removed DownloadTask rows: $removed');

  final userSetting = await database.userSettings.get();
  if (userSetting == null) {
    throw Exception('Global setting not found');
  }

  userSetting.globalSetting = userSetting.globalSetting.copyWith(
    dynamicColor: false,
    seedColor: colorThemeList[6].color,
  );
  await database.userSettings.put(userSetting);

  logger.d(
    '[migration_v3_to_v4] updated global setting: dynamicColor=false, '
    'seedColor=${colorThemeList[6].label}'
    '(${colorThemeList[6].color.toARGB32()})',
  );
}
