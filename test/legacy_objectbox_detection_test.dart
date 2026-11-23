import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zephyr/object_box/migration/compatible.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('breeze_legacy_db_');
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test('空目录视为没有旧 ObjectBox 数据库', () {
    expect(hasLegacyObjectBoxDatabase(root.path), isFalse);

    final legacy = Directory(p.join(root.path, 'breeze_db'))
      ..createSync(recursive: true);
    File(p.join(legacy.path, 'lock.mdb')).writeAsBytesSync(const <int>[1]);
    expect(hasLegacyObjectBoxDatabase(root.path), isFalse);
  });

  test('data.mdb 或归档 data.mdb.7z 都算旧库存在', () {
    final legacy = Directory(p.join(root.path, 'breeze_db'))
      ..createSync(recursive: true);

    final data = File(p.join(legacy.path, 'data.mdb'))
      ..writeAsBytesSync(const <int>[1]);
    expect(hasLegacyObjectBoxDatabase(root.path), isTrue);

    data.deleteSync();
    File(p.join(legacy.path, 'data.mdb.7z')).writeAsBytesSync(const <int>[1]);
    expect(hasLegacyObjectBoxDatabase(root.path), isTrue);
  });

  test('根目录旧归档也算旧库存在', () {
    File(p.join(root.path, 'data.mdb.7z')).writeAsBytesSync(const <int>[1]);
    expect(hasLegacyObjectBoxDatabase(root.path), isTrue);
  });
}
