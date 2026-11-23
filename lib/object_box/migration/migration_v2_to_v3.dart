import 'package:zephyr/database/database.dart';
import 'package:zephyr/main.dart';

Future<void> migrateV2ToV3(Database database) async {
  final removed = await database.downloadTasks.removeAll();
  logger.d('[migration_v2_to_v3] removed DownloadTask rows: $removed');
}
