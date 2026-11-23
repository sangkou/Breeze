import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:path/path.dart' as p;
import 'package:zephyr/config/global/global_setting.dart';
import 'package:zephyr/database/database.dart';
import 'package:zephyr/cubit/string_select.dart';
import 'package:zephyr/main.dart';
import 'package:zephyr/util/storage/get_path.dart';

import 'package:zephyr/object_box/migration/migration_v1_to_v2.dart';
import 'package:zephyr/object_box/migration/migration_v2_to_v3.dart';
import 'package:zephyr/object_box/migration/migration_v3_to_v4.dart';
import 'package:zephyr/object_box/migration/migration_v4_to_v5.dart';
import 'package:zephyr/object_box/migration/migration_v5_to_v6.dart';
import 'package:zephyr/object_box/migration/migration_v6_to_v7.dart';
import 'package:zephyr/object_box/migration/migration_v7_to_v8.dart';
import 'package:zephyr/object_box/migration/migration_v8_to_v9.dart';
import 'package:zephyr/object_box/migration/migration_v9_to_v10.dart';
import 'package:zephyr/object_box/migration/migration_v10_to_v11.dart';
import 'package:zephyr/object_box/migration/migration_v11_to_v12.dart';

const _defaultCompatibleVersion = 'v1';
const _latestCompatibleVersion = 'v12';

/// 旧 ObjectBox 数据库是否真实存在。
///
/// 迁移完成后 `data.mdb` 会被归档成 `data.mdb.7z`，所以归档文件也算存在；
/// 只看 `data.mdb` 会把“已经导入但兼容迁移还没跑”的升级用户误判为全新安装。
/// 根目录的旧归档也一并识别，避免历史版本归档位置差异导致漏判。
bool hasLegacyObjectBoxDatabase(String dbRoot) {
  const candidates = <String>[
    'breeze_db/data.mdb',
    'breeze_db/data.mdb.7z',
    'data.mdb',
    'data.mdb.7z',
  ];
  for (final relative in candidates) {
    if (File(p.join(dbRoot, relative)).existsSync()) {
      return true;
    }
  }
  return false;
}

Future<void> ensureCompatibleMigration(BuildContext context) async {
  try {
    final dbRoot = await getDbPath();
    if (!hasLegacyObjectBoxDatabase(dbRoot)) {
      final version = await getCompatibleVersion(database);
      if (version != _latestCompatibleVersion) {
        await setCompatibleVersion(database, _latestCompatibleVersion);
        if (context.mounted) {
          await _refreshGlobalSetting(context.read<GlobalSettingCubit>());
        }
        logger.i(
          '[compatible-migration] 未找到旧 ObjectBox 数据，直接标记 '
          '$_latestCompatibleVersion',
        );
      }
      return;
    }

    var version = await getCompatibleVersion(database);
    var migrated = false;

    if (version == 'v1' || version == 'v2') {
      if (context.mounted) {
        context.read<StringSelectCubit>().setDate('数据迁移中，请耐心等待');
      }
    }

    if (version == 'v1') {
      await migrateV1ToV2(database);
      await migrateLegacyDownloadFilesToPluginUuidLayout();
      await setCompatibleVersion(database, 'v2');
      version = 'v2';
      migrated = true;
    }

    if (version == 'v2') {
      await migrateV2ToV3(database);
      await setCompatibleVersion(database, 'v3');
      version = 'v3';
      migrated = true;
    }

    if (version == 'v3') {
      await migrateV3ToV4(database);
      await setCompatibleVersion(database, 'v4');
      version = 'v4';
      migrated = true;
    }

    if (version == 'v4') {
      await migrateV4ToV5(database);
      await setCompatibleVersion(database, 'v5');
      migrated = true;
      version = 'v5';
    }

    if (version == 'v5') {
      await migrateV5ToV6(database);
      await setCompatibleVersion(database, 'v6');
      migrated = true;
      version = 'v6';
    }

    if (version == 'v6') {
      await migrateV6ToV7(database);
      await setCompatibleVersion(database, 'v7');
      migrated = true;
      version = 'v7';
    }

    if (version == 'v7') {
      await migrateV7ToV8(database);
      await setCompatibleVersion(database, 'v8');
      migrated = true;
      version = 'v8';
    }

    if (version == 'v8') {
      await migrateV8ToV9(database);
      await setCompatibleVersion(database, 'v9');
      migrated = true;
      version = 'v9';
    }

    if (version == 'v9') {
      await migrateV9ToV10(database);
      await setCompatibleVersion(database, 'v10');
      migrated = true;
      version = 'v10';
    }
    if (version == 'v10') {
      await migrateV10ToV11(database);
      await setCompatibleVersion(database, 'v11');
      migrated = true;
      version = 'v11';
    }

    if (version == 'v11') {
      await migrateV11ToV12(database);
      await setCompatibleVersion(database, _latestCompatibleVersion);
      migrated = true;
      version = 'v12';
    }

    if (migrated && context.mounted) {
      await _refreshGlobalSetting(context.read<GlobalSettingCubit>());
    }
  } catch (e, stackTrace) {
    logger.e('Compatible migration failed', error: e, stackTrace: stackTrace);
  }
}

Future<void> _refreshGlobalSetting(GlobalSettingCubit cubit) async {
  final setting = await database.userSettings.get();
  if (setting == null) {
    return;
  }
  cubit.updateALl(setting.globalSetting);
}

Future<String> getCompatibleVersion(Database database) async {
  final setting = await database.userSettings.get();
  if (setting == null) {
    throw Exception('Global setting not found');
  }
  final version = setting.globalSetting.compatibleVersion;
  return version.isEmpty ? _defaultCompatibleVersion : version;
}

Future<void> setCompatibleVersion(Database database, String version) async {
  final setting = await database.userSettings.get();
  if (setting == null) {
    throw Exception('Global setting not found');
  }
  setting.globalSetting = setting.globalSetting.copyWith(
    compatibleVersion: version,
  );
  await database.userSettings.put(setting);
}
