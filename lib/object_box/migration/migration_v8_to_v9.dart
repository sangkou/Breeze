import 'package:zephyr/config/global/global_setting.dart';
import 'package:zephyr/database/database.dart';
import 'package:zephyr/main.dart';

/// v8 -> v9: 旧 SOCKS5 开关迁移到通用代理配置 ProxySettingState。
Future<void> migrateV8ToV9(Database database) async {
  final userSetting = await database.userSettings.get();
  if (userSetting == null) {
    throw Exception('Global setting not found');
  }

  final current = userSetting.globalSetting;
  final hasSocks5 = current.socks5Proxy.trim().isNotEmpty;
  final next = current.copyWith(
    proxySetting: ProxySettingState(
      enabled: current.socks5ProxyEnabled,
      type: hasSocks5 ? ProxyType.socks5 : ProxyType.http,
      address: current.socks5Proxy,
    ),
  );
  userSetting.globalSetting = next;
  await database.userSettings.put(userSetting);

  logger.d(
    '[migration_v8_to_v9] proxyEnabled=${next.proxySetting.enabled} '
    'proxyType=${next.proxySetting.type.name} '
    '(proxy=${next.proxySetting.address.isEmpty ? "empty" : "set"})',
  );
}
