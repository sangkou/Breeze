import 'dart:convert';

import 'package:zephyr/util/text/chinese_convert.dart';

/// 构建列表本地搜索用的归一化文本。
///
/// 纯 Dart（`t2s` 走 Rust OpenCC，同步 FFI），可以在 compute isolate 内调用。
String buildComicSearchText(dynamic comic) {
  final text = [
    comic.comicId?.toString() ?? '',
    comic.title?.toString() ?? '',
    comic.description?.toString() ?? '',
    _creatorName(comic.creator?.toString() ?? ''),
    comic.titleMeta?.toString() ?? '',
    comic.metadata?.toString() ?? '',
    comic.source?.toString() ?? '',
  ].join();
  return normalizeSearchText(text);
}

String _creatorName(String raw) {
  if (raw.trim().isEmpty) return '';
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map) return decoded['name']?.toString() ?? '';
  } catch (_) {}
  return '';
}

String normalizeSearchText(String text) {
  final lower = text.trim().toLowerCase();
  if (lower.isEmpty) return '';
  try {
    return t2s(lower);
  } catch (_) {
    return lower;
  }
}
