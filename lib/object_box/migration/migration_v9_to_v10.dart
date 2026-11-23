import 'package:zephyr/database/database.dart';
import 'package:zephyr/main.dart';

Future<void> migrateV9ToV10(Database database) async {
  final count = await database.downloadTasks.removeAll();
  logger.i('[migration_v9_to_v10] 已清理 $count 条旧下载任务记录');
}
