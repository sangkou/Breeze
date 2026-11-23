import 'dart:io';

import 'package:material_ui/material_ui.dart';

/// 鸿蒙启动冒烟入口。
///
/// 只验证 Flutter 引擎、渲染和 Dart 运行时能启动；不初始化数据库、
/// 插件运行时、Rust FFI、Sentry、通知等任何业务服务。
///
/// 构建：
/// ```bash
/// flutter build hap -t tool/ohos/smoke.dart --debug
/// ```
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const BreezeOhosSmokeApp());
}

class BreezeOhosSmokeApp extends StatelessWidget {
  const BreezeOhosSmokeApp({super.key});

  @override
  Widget build(BuildContext context) {
    // 官方 Flutter 没有 Platform.isOhos；统一用 operatingSystem 字符串判断，
    // 避免主分支因为引用不存在的 API 而编译失败。
    final isOhos = Platform.operatingSystem == 'ohos';

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.green, useMaterial3: true),
      home: Scaffold(
        appBar: AppBar(title: const Text('Breeze · OHOS smoke test')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isOhos ? Icons.check_circle : Icons.info_outline,
                  size: 72,
                  color: isOhos ? Colors.green : Colors.orange,
                ),
                const SizedBox(height: 16),
                Text(
                  'Flutter 启动成功',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                Text('Platform: ${Platform.operatingSystem}'),
                Text('Version: ${Platform.operatingSystemVersion}'),
                const SizedBox(height: 24),
                const Text(
                  '数据库 / 插件 / Rust 初始化均已跳过',
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
