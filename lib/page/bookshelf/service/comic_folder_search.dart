// 文件夹搜索匹配工具。
//
// 纯字符串逻辑，不依赖 Flutter / ObjectBox，便于单独做单元测试。

/// 把输入拆成搜索词：按空白切分并统一小写，忽略空串。
///
/// 多个搜索词之间是「与」关系：每个词都要在名称或完整路径中命中。
List<String> splitFolderSearchTerms(String raw) {
  final terms = <String>[];
  for (final part in raw.toLowerCase().split(RegExp(r'\s+'))) {
    if (part.isEmpty) continue;
    terms.add(part);
  }
  return terms;
}

/// 名称或完整路径命中全部搜索词时返回 true。
bool folderMatchesSearchTerms({
  required List<String> terms,
  required String name,
  required String path,
}) {
  if (terms.isEmpty) return true;
  final haystack = '${name.toLowerCase()} ${path.toLowerCase()}';
  return terms.every(haystack.contains);
}

/// 生成 [text] 的高亮掩码：命中任一搜索词的字符位置标记为 true。
///
/// 名称与路径分别调用，用于在搜索结果里高亮命中的片段。
List<bool> buildFolderSearchHighlightMask(String text, List<String> terms) {
  final mask = List<bool>.filled(text.length, false, growable: false);
  if (text.isEmpty || terms.isEmpty) return mask;
  final lower = text.toLowerCase();
  for (final term in terms) {
    if (term.isEmpty) continue;
    var index = lower.indexOf(term);
    while (index >= 0) {
      // 小写转换在少数语言下会改变长度，这里按掩码长度裁一下避免越界。
      final end = (index + term.length).clamp(0, mask.length);
      for (var i = index; i < end; i++) {
        mask[i] = true;
      }
      index = lower.indexOf(term, index + term.length);
    }
  }
  return mask;
}
