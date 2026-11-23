import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zephyr/database/app_database.dart';

void main() {
  test(
    'new database uses auto_vacuum=INCREMENTAL and keeps it on reopen',
    () async {
      final temp = await Directory.systemTemp.createTemp('breeze_autovac_');
      final path = p.join(temp.path, 'breeze.sqlite3');
      try {
        final db = await openAppDatabase(
          path: path,
          legacyObjectBoxDir: p.join(temp.path, 'missing_objectbox'),
        );
        try {
          final rows = await db.query('PRAGMA auto_vacuum');
          expect(rows.single['auto_vacuum'], 2);
        } finally {
          await db.close();
        }

        final reopened = await openAppDatabase(
          path: path,
          legacyObjectBoxDir: p.join(temp.path, 'missing_objectbox'),
        );
        try {
          final rows = await reopened.query('PRAGMA auto_vacuum');
          expect(rows.single['auto_vacuum'], 2);
        } finally {
          await reopened.close();
        }
      } finally {
        await temp.delete(recursive: true);
      }
    },
  );
}
