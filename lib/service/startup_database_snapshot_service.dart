import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:zephyr/database/database.dart';
import 'package:zephyr/main.dart' as app;
import 'package:zephyr/src/rust/api/simple.dart';
import 'package:zephyr/util/async/worker_pool.dart';
import 'package:zephyr/util/storage/get_path.dart';
import 'package:zephyr/util/rust/rust_loader.dart';

const _startupDatabaseSnapshotFileName = 'database_snapshot.br';

class _SnapshotTask {
  const _SnapshotTask({required this.handle, required this.path});

  final int handle;
  final String path;
}

/// 启动时异步生成数据库快照（Brotli 压缩）。
///
/// 全库读取、JSON 编码、压缩与落盘都在 worker 池内完成。
Future<void> saveStartupDatabaseSnapshot() async {
  try {
    final snapshotPath = p.join(
      await getFilePath(),
      _startupDatabaseSnapshotFileName,
    );
    final task = _SnapshotTask(
      handle: app.database.db.handle,
      path: snapshotPath,
    );
    await runInWorker(() => _writeSnapshotInWorker(task));
    app.logger.i('数据库启动快照已更新：$snapshotPath');
  } catch (error, stackTrace) {
    app.logger.e('更新数据库启动快照失败', error: error, stackTrace: stackTrace);
  }
}

Future<void> _writeSnapshotInWorker(_SnapshotTask task) async {
  await initRustLib();
  final json = await Database.fromHandle(task.handle).collectAllDataJson();
  final compressed = await compressExtreme(data: utf8.encode(json));
  await File(task.path).writeAsBytes(compressed, flush: true);
}
