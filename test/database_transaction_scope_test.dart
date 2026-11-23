import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zephyr/database/database.dart';
import 'package:zephyr/object_box/model.dart';

void main() {
  test(
    'repository writes join the ambient transaction and roll back',
    () async {
      final temp = await Directory.systemTemp.createTemp('breeze_tx_scope_');
      final database = await Database.open(
        path: p.join(temp.path, 'breeze.sqlite3'),
        legacyObjectBoxDir: p.join(temp.path, 'missing'),
      );
      try {
        final favorite = UnifiedComicFavorite(
          uniqueKey: 'test:a',
          source: 'test',
          comicId: 'a',
          title: 'A',
          description: '',
          cover: '',
          creator: '',
          titleMeta: '',
          metadata: '',
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
          deleted: false,
          schemaVersion: 1,
        );

        await expectLater(
          database.transaction((_) async {
            await database.favorites.put(favorite);
            expect(await database.favorites.count(), 1);
            throw StateError('rollback');
          }),
          throwsStateError,
        );
        expect(await database.favorites.count(), 0);

        await database.transaction((_) async {
          await database.favorites.put(favorite);
        });
        expect(await database.favorites.count(), 1);

        final exported = jsonDecode(
          await database.collectAllDataJson(removeIds: true),
        ) as Map<String, dynamic>;
        expect(exported['unifiedComicFavorite'], hasLength(1));
        expect((exported['unifiedComicFavorite'] as List).first['id'], isNull);
      } finally {
        await database.close();
        await temp.delete(recursive: true);
      }
    },
  );

  test('old JSON rows get model defaults for missing fields', () {
    final history = UnifiedComicHistory.fromJson(const <String, dynamic>{
      'uniqueKey': 'test:a',
      'source': 'test',
      'comicId': 'a',
    });
    expect(history.lastReadAt, DateTime.utc(1970));
    expect(history.deleted, isFalse);
    expect(history.schemaVersion, 0);

    final preference = ComicReadPreference.fromJson(const <String, dynamic>{
      'uniqueKey': 'test:a',
      'source': 'test',
      'comicId': 'a',
    });
    expect(preference.overridesJson, '{"readMode":0}');
    expect(preference.deleted, isFalse);
  });
}
