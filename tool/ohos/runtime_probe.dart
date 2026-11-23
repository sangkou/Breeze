import 'dart:io';

// 探针只验证启动链路，用 SDK 自带 material，避免依赖 UI fork。
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:zephyr/database/database.dart';
import 'package:zephyr/src/rust/api/simple.dart' as rust_simple;
import 'package:zephyr/util/ohos/platform_plugins.dart';
import 'package:zephyr/util/rust/rust_loader.dart';

/// OHOS 启动探针：逐项执行启动依赖并把结果画到屏幕上。
///
/// 不初始化插件/网络/Sentry，只验证 FRB、path_provider、SQLite。
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  installOhosPlatformPlugins();
  runApp(const _ProbeApp());
}

class _ProbeApp extends StatelessWidget {
  const _ProbeApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: const _ProbePage(),
    );
  }
}

class _ProbePage extends StatefulWidget {
  const _ProbePage();

  @override
  State<_ProbePage> createState() => _ProbePageState();
}

class _ProbePageState extends State<_ProbePage> {
  final List<String> _lines = <String>[];

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _step(String name, Future<Object?> Function() body) async {
    setState(() => _lines.add('… $name'));
    try {
      final result = await body();
      setState(() => _lines.add('✅ $name: $result'));
    } catch (error, stack) {
      setState(() => _lines.add('❌ $name: $error\n$stack'));
    }
  }

  Future<void> _run() async {
    await _step('initRustLib', () async {
      await initRustLib();
      return 'ok';
    });
    await _step('rust greet', () async {
      return rust_simple.greet(name: 'ohos');
    });
    Object? support;
    await _step('getApplicationSupportDirectory', () async {
      support = await getApplicationSupportDirectory();
      return (support as Directory).path;
    });
    await _step('getTemporaryDirectory', () async {
      final dir = await getTemporaryDirectory();
      return dir.path;
    });
    await _step('Database.open', () async {
      final dir = support;
      if (dir is! Directory) return 'skipped (no support dir)';
      final dbDir = Directory(p.join(dir.path, 'probe_db'));
      await dbDir.create(recursive: true);
      final db = await Database.open(
        path: p.join(dbDir.path, 'probe.sqlite3'),
        legacyObjectBoxDir: p.join(dbDir.path, 'legacy_obx'),
        archiveLegacyData: false,
      );
      final rows = await db.query('SELECT 1 AS ok');
      return 'rows=$rows';
    });
    await _step('done', () async => 'probe finished');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Breeze OHOS probe')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          for (final line in _lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(line, style: const TextStyle(fontSize: 14)),
            ),
        ],
      ),
    );
  }
}
