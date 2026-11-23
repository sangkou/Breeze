import 'package:zephyr/config/global/global_setting.dart';
import 'package:zephyr/network/sync/sync_service.dart';
import 'package:zephyr/network/sync/webdav_sync_service.dart';

Future<void> testWebDavServer() async {
  final service = WebDavSyncService(globalSetting);
  await service.testConnection();
}

Future<void> syncWithWebDav() async {
  await autoSync(globalSetting);
}
