import 'package:url_launcher/url_launcher.dart';
import 'package:zephyr/util/ohos/platform.dart';
import 'package:zephyr/util/ohos/file_bridge.dart';

/// 用系统浏览器/对应应用打开外部链接。
///
/// OHOS 没有 url_launcher 实现，走应用自己的 startAbility 通道；
/// 其他平台保持原来 url_launcher 的行为。
Future<bool> openExternalUrl(Uri uri) async {
  try {
    if (isOhos) {
      return await openOhosUrl(uri.toString());
    }
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}
