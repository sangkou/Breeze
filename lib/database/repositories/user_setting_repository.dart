import 'dart:convert';

import 'package:zephyr/database/db.dart';
import 'package:zephyr/database/db_read.dart';
import 'package:zephyr/object_box/model.dart';

class UserSettingRepository {
  final BreezeDatabase db;
  Future<void> _writeChain = Future<void>.value();

  UserSettingRepository(this.db);

  Future<T> _enqueueWrite<T>(Future<T> Function() action) {
    final next = _writeChain.then((_) => action());
    _writeChain = next.then<void>((_) {}, onError: (_) {});
    return next;
  }

  Future<UserSetting?> get() => runDbRead(
    db,
    sql: 'SELECT * FROM "UserSetting" WHERE "id" = 1 LIMIT 1',
    decode: _decodeFirst,
  );

  Future<UserSetting> getOrCreate() async {
    final existing = await get();
    if (existing != null) return existing;
    final setting = UserSetting();
    await put(setting);
    return setting;
  }

  Future<void> put(UserSetting setting) {
    if (db.inTransaction) return _doPut(setting);
    return _enqueueWrite(() => _doPut(setting));
  }

  Future<void> _doPut(UserSetting setting) async {
    await db.execute(
      'INSERT INTO "UserSetting" '
      '("id","globalSettingData","bikaSettingData","jmSettingData","jmJwt") '
      'VALUES (1,?,?,?,?) '
      'ON CONFLICT("id") DO UPDATE SET '
      '"globalSettingData"=excluded."globalSettingData",'
      '"bikaSettingData"=excluded."bikaSettingData",'
      '"jmSettingData"=excluded."jmSettingData",'
      '"jmJwt"=excluded."jmJwt"',
      <Object?>[
        setting.globalSettingData,
        setting.bikaSettingData,
        setting.jmSettingData,
        setting.jmJwt,
      ],
    );
  }

  Future<String?> getGlobalSettingData() => runDbRead(
    db,
    sql: 'SELECT "globalSettingData" FROM "UserSetting" WHERE "id" = 1',
    decode: _decodeGlobalSettingData,
  );

  Future<void> putGlobalSettingData(String data) {
    if (db.inTransaction) return _doPutGlobalSettingData(data);
    return _enqueueWrite(() => _doPutGlobalSettingData(data));
  }

  Future<void> _doPutGlobalSettingData(String data) async {
    await db.execute(
      'INSERT INTO "UserSetting" ("id","globalSettingData","jmJwt") '
      'VALUES (1,?, \'\') '
      'ON CONFLICT("id") DO UPDATE SET '
      '"globalSettingData"=excluded."globalSettingData"',
      <Object?>[data],
    );
  }

  static UserSetting _decode(Map<String, dynamic> row) {
    return UserSetting.fromJson(<String, dynamic>{
      ...row,
      'globalSetting': _settingMap(row['globalSettingData']),
      'bikaSetting': _settingMap(row['bikaSettingData']),
      'jmSetting': _settingMap(row['jmSettingData']),
    });
  }

  static UserSetting? _decodeFirst(List<Map<String, dynamic>> rows) =>
      rows.isEmpty ? null : _decode(rows.first);

  static String? _decodeGlobalSettingData(List<Map<String, dynamic>> rows) =>
      rows.isEmpty ? null : rows.first['globalSettingData'] as String?;

  static Map<String, dynamic> _settingMap(Object? raw) {
    if (raw is String && raw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) return decoded;
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {}
    }
    return const <String, dynamic>{};
  }
}
