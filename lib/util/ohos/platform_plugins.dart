import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:zephyr/util/ohos/platform.dart';
import 'package:zephyr/util/ohos/file_selector.dart';
import 'package:zephyr/util/ohos/path_provider.dart';
import 'package:zephyr/util/ohos/shared_preferences.dart';

/// 在 OHOS 启动早期注册应用内的平台实现。
///
/// 这些实现不再依赖 `third_party/ohos_plugins` 的独立 OHOS 模块，
/// 原生能力统一由 `BreezeOhosPlugin` 提供。
void installOhosPlatformPlugins() {
  if (!isOhos) return;
  PathProviderPlatform.instance = OhosPathProvider();
  SharedPreferencesStorePlatform.instance = OhosSharedPreferences();
  FileSelectorPlatform.instance = OhosFileSelector();
}
