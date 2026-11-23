import 'package:zephyr/database/database.dart';
import 'package:zephyr/main.dart';

/// v7 -> v8: 为 SOCKS5 代理增加开关字段 sock5ProxyEnabled。
Future<void> migrateV7ToV8(Database database) async {
  final userSetting = await database.userSettings.get();
  if (userSetting == null) {
    throw Exception('Global setting not found');
  }

  final current = userSetting.globalSetting;
  final hasProxy = current.socks5Proxy.trim().isNotEmpty;
  userSetting.globalSetting = current.copyWith(socks5ProxyEnabled: hasProxy);
  await database.userSettings.put(userSetting);

  logger.d(
    '[migration_v7_to_v8] socks5ProxyEnabled=$hasProxy '
    '(proxy=${hasProxy ? current.socks5Proxy : "empty"})',
  );
}
