import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:path/path.dart' as p;
import 'package:zephyr/page/setting/data_backup/backup_restore.dart';
import 'package:zephyr/service/update/check_update.dart';
import 'package:zephyr/config/global/global_setting.dart';
import 'package:zephyr/i18n/strings.g.dart';
import 'package:zephyr/main.dart';
import 'package:zephyr/src/rust/api/data_backup.dart';
import 'package:zephyr/util/storage/get_path.dart';
import 'package:zephyr/widgets/toast.dart';

/// 备份包配置信息。
class BackupConfig {
  final String version;
  final bool includeDownloads;

  /// 本次导入使用的临时根目录，包含 zip 缓存副本与解压目录。
  final String cacheDir;

  /// 解压目录路径。
  final String extractDir;

  /// 缓存目录中的 zip 副本路径。
  final String zipPath;

  BackupConfig({
    required this.version,
    required this.includeDownloads,
    required this.cacheDir,
    required this.extractDir,
    required this.zipPath,
  });
}

/// 导出完整数据备份到 [zipPath]。
///
/// 当 [includeDownloads] 为 true 时，会一并打包 `getDownloadPath()` 下的漫画文件。
Future<String> exportBreezeBackup({
  required String zipPath,
  required bool includeDownloads,
}) async {
  final cachePath = await getCachePath();
  final tempDir = await Directory(
    p.join(
      cachePath,
      'breeze_backup',
      DateTime.now().millisecondsSinceEpoch.toString(),
    ),
  ).create(recursive: true);

  try {
    // 1. 写入 config.json
    final version = await getAppVersion();
    final config = <String, dynamic>{
      'version': version,
      'includeDownloads': includeDownloads,
      'exportedAt': DateTime.now().toIso8601String(),
    };
    await File(p.join(tempDir.path, 'config.json'))
        .writeAsString(jsonEncode(config));

    // 2. 写入 objectbox.json（文件名保持与旧版备份兼容）
    await database.writeAllDataJsonFileAsync(
      p.join(tempDir.path, 'objectbox.json'),
      removeIds: true,
    );

    // 3. 调用 Rust 流式打包
    await createDataBackupZip(
      zipPath: zipPath,
      dataDir: tempDir.path,
      downloadDir: includeDownloads ? await getDownloadPath() : null,
    );

    return zipPath;
  } finally {
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  }
}

/// 读取备份包中的 config.json，并把 zip 复制到应用缓存目录后返回配置信息。
///
/// 先把源 zip 复制到私有缓存，再读取 config.json，避免在确认导入前因权限
/// 回收或源文件变动导致第二次读取失败。本函数不会解压整个 zip。
/// 调用方在确认导入后应使用 [applyBreezeBackupImport]；若取消导入，
/// 请自行删除 [BackupConfig.cacheDir]。
///
/// 当 [skipCopy] 为 true 时，[sourceZipPath] 应已是私有缓存中的路径，
/// 不再重复复制（用于 Android 原生选择器直接拷贝到目标位置的场景）。
Future<BackupConfig> readBackupConfig(
  String sourceZipPath, {
  bool skipCopy = false,
}) async {
  final cachePath = await getCachePath();
  // Android 原生选择器已经直接拷贝到私有缓存，复用该目录避免重复拷贝和路径不一致
  final cacheDir = skipCopy
      ? Directory(p.dirname(p.dirname(sourceZipPath)))
      : Directory(
          p.join(
            cachePath,
            'breeze_backup_import',
            DateTime.now().millisecondsSinceEpoch.toString(),
          ),
        );
  final extractDir = Directory(p.join(cacheDir.path, 'extract'));
  final cacheZipFile = File(p.join(cacheDir.path, 'zip', 'backup.zip'));

  try {
    await extractDir.create(recursive: true);
    await cacheZipFile.parent.create(recursive: true);
    if (!skipCopy) {
      await File(sourceZipPath).copy(cacheZipFile.path);
    }

    final configJson = await readDataBackupConfig(zipPath: cacheZipFile.path);
    final config = jsonDecode(configJson) as Map<String, dynamic>;
    return BackupConfig(
      version: config['version'] as String? ?? 'Unknown',
      includeDownloads: config['includeDownloads'] as bool? ?? false,
      cacheDir: cacheDir.path,
      extractDir: extractDir.path,
      zipPath: cacheZipFile.path,
    );
  } catch (e) {
    logger.e(e);
    showErrorToast('${t.dataBackup.importFailed}：$e');
    // 失败时清理全部临时目录，避免残留
    try {
      await cacheDir.delete(recursive: true);
    } catch (_) {}
    rethrow;
  }
}

const _filePickerChannel = MethodChannel('com.zephyr.breeze/file_picker');

/// Android 原生选择 zip 文件并直接拷贝到应用缓存目录。
///
/// 返回缓存中的 zip 路径；用户取消时返回 null。该路径可直接交给
/// [readBackupConfig] 且应设置 [skipCopy] 为 true，避免重复拷贝。
Future<String?> pickBackupZipAndroid() async {
  final cachePath = await getCachePath();
  final cacheDir = Directory(
    p.join(
      cachePath,
      'breeze_backup_import',
      DateTime.now().millisecondsSinceEpoch.toString(),
    ),
  );
  final cacheZipFile = File(p.join(cacheDir.path, 'zip', 'backup.zip'));
  await cacheZipFile.parent.create(recursive: true);

  logger.i('调用 Android 原生选择器，目标路径：${cacheZipFile.path}');
  String? result;
  try {
    result = await _filePickerChannel.invokeMethod<String>('pickBackupZip', {
      'destPath': cacheZipFile.path,
    });
  } on PlatformException catch (e) {
    // 部分外置存储/SD 卡无法解析路径，原生侧会抛 UnsupportedOperationException。
    logger.w('原生文件选择器失败', error: e);
    showErrorToast('${t.dataBackup.selectBackupFailed}：${e.message ?? e.code}');
  }
  logger.i('Android 原生选择器返回：$result');
  if (result == null) {
    // 用户取消选择，清理已创建的临时目录
    try {
      await cacheDir.delete(recursive: true);
    } catch (_) {}
  }
  return result;
}

/// 将备份数据解压并应用到当前应用。
///
/// [config] 应来自 [readBackupConfig] 的返回值。执行完成后会删除
/// [BackupConfig.cacheDir] 下的缓存副本与解压目录。
Future<void> applyBreezeBackupImport(BackupConfig config) async {
  final cacheDirectory = Directory(config.cacheDir);
  try {
    // 1. 解压完整备份包
    await extractDataBackupZip(
      zipPath: config.zipPath,
      extractDir: config.extractDir,
    );

    // 解压完成后即可删除缓存的 zip 副本，减少磁盘占用
    try {
      await File(config.zipPath).delete();
    } catch (_) {}

    final configFile = File(p.join(config.extractDir, 'config.json'));
    final backupConfig =
        jsonDecode(await configFile.readAsString()) as Map<String, dynamic>;
    final includeDownloads = backupConfig['includeDownloads'] as bool? ?? false;

    // 2. 清空并恢复数据库数据（单事务：失败时保留导入前的数据）
    // 若备份不包含下载文件，则保留本机下载相关记录，避免下载记录被清空后
    // 已下载文件变成“孤儿文件”。整段读写放在 worker 池：备份 JSON 的
    // 解码与逐表 fromJson/写入都不占 UI isolate。
    final objectBoxFile = File(p.join(config.extractDir, 'objectbox.json'));
    final task = RestoreBackupTask(
      handle: database.db.handle,
      dataJsonPath: await objectBoxFile.exists() ? objectBoxFile.path : null,
      includeDownloads: includeDownloads,
    );
    final restoredGlobal = await importBackupData(task);
    if (restoredGlobal != null) {
      _applyRestoredGlobalSetting(restoredGlobal);
    }

    // 4. 恢复下载文件
    if (includeDownloads) {
      final exportedDownloadsDir = Directory(
        p.join(config.extractDir, 'downloads'),
      );
      if (await exportedDownloadsDir.exists()) {
        final currentDownloadDir = Directory(await getDownloadPath());
        if (await currentDownloadDir.exists()) {
          await currentDownloadDir.delete(recursive: true);
        }
        await _moveDirectory(exportedDownloadsDir, currentDownloadDir);
      }
    }
  } finally {
    try {
      await cacheDirectory.delete(recursive: true);
    } catch (_) {}
  }
}

/// 把恢复后的全局设置推回内存缓存与界面。
///
/// 优先使用导航器上下文里的 [GlobalSettingCubit]；应用尚未挂载 UI 时，
/// 用一个游离 cubit 至少刷新模块级 `globalSetting` 缓存。
void _applyRestoredGlobalSetting(GlobalSettingState value) {
  final context = navigatorKey.currentContext;
  if (context != null && context.mounted) {
    BlocProvider.of<GlobalSettingCubit>(context).applySyncedState(value);
    return;
  }
  logger.w('备份恢复时未找到 GlobalSettingCubit，仅刷新进程内缓存');
  GlobalSettingCubit().applySyncedState(value);
}

/// 尽可能使用重命名移动目录；失败时回退到递归复制。
Future<void> _moveDirectory(Directory source, Directory target) async {
  try {
    await source.rename(target.path);
  } on FileSystemException catch (_) {
    await target.create(recursive: true);
    await for (final entity in source.list(recursive: false)) {
      final newPath = p.join(target.path, p.basename(entity.path));
      if (entity is Directory) {
        await _moveDirectory(entity, Directory(newPath));
      } else if (entity is File) {
        await entity.copy(newPath);
      }
    }
    await source.delete(recursive: true);
  }
}
