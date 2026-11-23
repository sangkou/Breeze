import 'package:zephyr/database/database.dart';
import 'package:zephyr/main.dart';

Future<void> migrateV10ToV11(Database database) async {
  final count = await database.downloadTasks.removeAll();
  logger.i('[migration_v10_to_v11] 已清理 $count 条旧下载任务记录');
}
