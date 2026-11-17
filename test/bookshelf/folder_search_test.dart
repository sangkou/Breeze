import 'package:flutter_test/flutter_test.dart';
import 'package:zephyr/page/bookshelf/service/comic_folder_search.dart';

void main() {
  group('splitFolderSearchTerms', () {
    test('空输入得到空词表', () {
      expect(splitFolderSearchTerms(''), isEmpty);
      expect(splitFolderSearchTerms('   '), isEmpty);
    });

    test('按空白切分并统一小写', () {
      expect(splitFolderSearchTerms('  Manga   Comic '), ['manga', 'comic']);
      expect(splitFolderSearchTerms('a\u3000b'), ['a', 'b']);
    });
  });

  group('folderMatchesSearchTerms', () {
    test('空词表视为匹配', () {
      expect(
        folderMatchesSearchTerms(terms: const [], name: '任意', path: '/任意'),
        isTrue,
      );
    });

    test('命中名称', () {
      expect(
        folderMatchesSearchTerms(
          terms: splitFolderSearchTerms('man'),
          name: 'Manga',
          path: '/收藏/Manga',
        ),
        isTrue,
      );
    });

    test('命中父级路径', () {
      expect(
        folderMatchesSearchTerms(
          terms: splitFolderSearchTerms('收藏'),
          name: 'Manga',
          path: '/收藏/Manga',
        ),
        isTrue,
      );
    });

    test('多个词必须全部命中（与关系）', () {
      expect(
        folderMatchesSearchTerms(
          terms: splitFolderSearchTerms('manga 收藏'),
          name: 'Manga',
          path: '/收藏/Manga',
        ),
        isTrue,
      );
      expect(
        folderMatchesSearchTerms(
          terms: splitFolderSearchTerms('manga 下载'),
          name: 'Manga',
          path: '/收藏/Manga',
        ),
        isFalse,
      );
    });
  });

  group('buildFolderSearchHighlightMask', () {
    test('大小写不敏感地标记命中区间', () {
      final mask = buildFolderSearchHighlightMask('Manga', ['man']);
      expect(mask.take(3).every((hit) => hit), isTrue);
      expect(mask.skip(3).any((hit) => hit), isFalse);
    });

    test('同一词多次出现都被标记', () {
      final mask = buildFolderSearchHighlightMask('a-b-a', ['a']);
      expect(mask, [true, false, false, false, true]);
    });

    test('空词表不标记任何字符', () {
      final mask = buildFolderSearchHighlightMask('Manga', const []);
      expect(mask.any((hit) => hit), isFalse);
      expect(mask.length, 5);
    });

    test('空文本返回空掩码', () {
      expect(buildFolderSearchHighlightMask('', ['a']), isEmpty);
    });
  });
}
