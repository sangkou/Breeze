import 'package:material_ui/material_ui.dart';
import 'package:zephyr/i18n/strings.g.dart';
import 'package:zephyr/page/webview_page.dart';

/// 验证 OHOS WebView 不支持提示页。
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  LocaleSettings.setLocale(AppLocale.zhCn);
  runApp(
    const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: WebViewPage(info: <String>['Example', 'https://example.com']),
    ),
  );
}
