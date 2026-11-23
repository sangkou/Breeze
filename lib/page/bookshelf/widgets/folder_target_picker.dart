import 'package:material_ui/material_ui.dart';
import 'package:zephyr/i18n/strings.g.dart';
import 'package:zephyr/main.dart';
import 'package:zephyr/object_box/model.dart';
import 'package:zephyr/page/bookshelf/service/comic_folder_search.dart';
import 'package:zephyr/page/bookshelf/service/comic_folder_service.dart';
import 'package:zephyr/widgets/toast.dart';

/// 文件夹目标选择器（书架移动/复制 + 详情页本地收藏共用）。
///
/// 路径以 `/a/b` 形式表示；根目录用 [kComicFolderRootPath]（空串）表示。
/// 返回选中的路径集合；返回 null 表示用户取消了选择。
/// [allowEmptyConfirm] 为 true 时允许空选确认（详情页用空选表示取消收藏）。
/// 文件夹较多时可在顶部搜索框按名称或完整路径过滤。
Future<Set<String>?> showFolderTargetPicker(
  BuildContext context, {
  required ComicFolderType type,
  Set<String> initialSelectedPaths = const {},
  bool multiSelect = true,
  bool rootEnabled = true,
  Set<String> disabledSyncIds = const {},
  bool allowCreateFolder = true,
  bool allowEmptyConfirm = false,
  String? title,
  String? currentSyncId,
}) {
  return showDialog<Set<String>>(
    context: context,
    builder: (_) => _FolderTargetPickerDialog(
      type: type,
      initialSelectedPaths: initialSelectedPaths,
      multiSelect: multiSelect,
      rootEnabled: rootEnabled,
      disabledSyncIds: disabledSyncIds,
      allowCreateFolder: allowCreateFolder,
      allowEmptyConfirm: allowEmptyConfirm,
      title: title,
      currentSyncId: currentSyncId,
    ),
  );
}

class _FolderTargetPickerDialog extends StatefulWidget {
  const _FolderTargetPickerDialog({
    required this.type,
    required this.initialSelectedPaths,
    required this.multiSelect,
    required this.rootEnabled,
    required this.disabledSyncIds,
    required this.allowCreateFolder,
    required this.allowEmptyConfirm,
    required this.title,
    required this.currentSyncId,
  });

  final ComicFolderType type;
  final Set<String> initialSelectedPaths;
  final bool multiSelect;
  final bool rootEnabled;
  final Set<String> disabledSyncIds;
  final bool allowCreateFolder;
  final bool allowEmptyConfirm;
  final String? title;
  final String? currentSyncId;

  @override
  State<_FolderTargetPickerDialog> createState() =>
      _FolderTargetPickerDialogState();
}

class _FolderTargetPickerDialogState extends State<_FolderTargetPickerDialog> {
  List<ComicFolder> _folders = const <ComicFolder>[];
  Map<String, String> _pathMap = const <String, String>{};

  /// 文件夹是异步查的，首次进入先显示加载态，避免闪一下「没有文件夹」。
  bool _loading = true;
  late final Set<String> _selectedPaths;
  final Set<String> _expandedPaths = <String>{};
  late final TextEditingController _searchController;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _selectedPaths = Set<String>.from(widget.initialSelectedPaths);
    _searchController = TextEditingController();
    _reloadFolders();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _reloadFolders() async {
    // 上游把文件夹查询改成了异步，这里跟着改成 await + setState。
    final folders = await ComicFolderService.listAllFolders(widget.type);
    if (!mounted) return;
    final syncIdMap = {for (final folder in folders) folder.syncId: folder};
    setState(() {
      _folders = folders;
      _loading = false;
      _pathMap = {
        for (final folder in folders)
          folder.syncId: ComicFolderService.folderPath(
            folder,
            syncIdMap: syncIdMap,
          ),
      };
    });
  }

  List<String> get _terms => splitFolderSearchTerms(_query);

  void _togglePath(String path) {
    setState(() {
      if (!widget.multiSelect) {
        _selectedPaths
          ..clear()
          ..add(path);
        return;
      }
      if (_selectedPaths.contains(path)) {
        _selectedPaths.remove(path);
      } else {
        _selectedPaths.add(path);
      }
    });
  }

  void _toggleExpanded(String path) {
    setState(() {
      if (_expandedPaths.contains(path)) {
        _expandedPaths.remove(path);
      } else {
        _expandedPaths.add(path);
      }
    });
  }

  Future<void> _createFolderAtRoot() async {
    final name = await _askFolderName(context);
    if (name == null || name.trim().isEmpty || !mounted) return;
    try {
      final folder = await ComicFolderService.createFolder(
        kComicFolderRootPath,
        name.trim(),
        widget.type,
      );
      await _reloadFolders();
      if (!mounted) return;
      setState(() {
        final newPath = _pathMap[folder.syncId] ?? '/${folder.name}';
        if (!widget.multiSelect) _selectedPaths.clear();
        _selectedPaths.add(newPath);
      });
    } catch (e) {
      logger.e(e);
      showErrorToast(e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final terms = _terms;
    final confirmEnabled =
        widget.allowEmptyConfirm || _selectedPaths.isNotEmpty;

    return AlertDialog(
      title: Row(
        children: [
          Expanded(child: Text(widget.title ?? t.bookshelf.selectTargetFolder)),
          if (widget.allowCreateFolder)
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: t.bookshelf.createFolder,
              onPressed: _createFolderAtRoot,
              icon: const Icon(Icons.create_new_folder_outlined),
            ),
        ],
      ),
      content: SizedBox(
        width: 380,
        height: 400,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildSearchField(),
            const SizedBox(height: 8),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : terms.isEmpty
                  ? _buildFolderTree()
                  : _buildSearchResults(terms),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.common.cancel),
        ),
        FilledButton(
          onPressed: confirmEnabled
              ? () => Navigator.of(context).pop(_selectedPaths)
              : null,
          child: Text(t.common.ok),
        ),
      ],
    );
  }

  Widget _buildSearchField() {
    return TextField(
      controller: _searchController,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        isDense: true,
        hintText: t.bookshelf.searchFolderHint,
        prefixIcon: const Icon(Icons.search, size: 20),
        suffixIcon: _query.isEmpty
            ? null
            : IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: t.common.clear,
                iconSize: 18,
                icon: const Icon(Icons.close),
                onPressed: () {
                  _searchController.clear();
                  setState(() => _query = '');
                },
              ),
        border: const OutlineInputBorder(),
      ),
      onChanged: (value) => setState(() => _query = value),
      onSubmitted: (_) => FocusManager.instance.primaryFocus?.unfocus(),
    );
  }

  Widget _buildFolderTree() {
    final forest = buildFolderForest(_folders, _pathMap);
    final list = ListView(
      children: [
        _RootTargetTile(
          selected: _selectedPaths.contains(kComicFolderRootPath),
          enabled: widget.rootEnabled,
          onTap: () => _togglePath(kComicFolderRootPath),
          singleValue: widget.multiSelect ? null : kComicFolderRootPath,
        ),
        const Divider(),
        ...forest.map(
          (node) => buildFolderTreeTile(
            context: context,
            node: node,
            pathMap: _pathMap,
            expandedPaths: _expandedPaths,
            forbiddenSyncIds: widget.disabledSyncIds,
            selectedPaths: _selectedPaths,
            singleSelect: !widget.multiSelect,
            currentSyncId: widget.currentSyncId,
            onToggleExpand: _toggleExpanded,
            onSelect: _togglePath,
          ),
        ),
      ],
    );
    if (widget.multiSelect) return list;
    return RadioGroup<String>(
      groupValue: _selectedPaths.singleOrNull,
      onChanged: (value) {
        if (value != null) _togglePath(value);
      },
      child: list,
    );
  }

  Widget _buildSearchResults(List<String> terms) {
    final hits = <_FolderSearchHit>[];
    for (final folder in _folders) {
      final path = _pathMap[folder.syncId] ?? '/${folder.name}';
      if (!folderMatchesSearchTerms(
        terms: terms,
        name: folder.name,
        path: path,
      )) {
        continue;
      }
      hits.add(_FolderSearchHit(folder: folder, path: path));
    }
    hits.sort((a, b) {
      final rankCompare = _searchRank(
        a.folder.name,
        terms.first,
      ).compareTo(_searchRank(b.folder.name, terms.first));
      if (rankCompare != 0) return rankCompare;
      return a.path.toLowerCase().compareTo(b.path.toLowerCase());
    });

    if (hits.isEmpty) return _buildEmptyResult();

    final theme = Theme.of(context);
    final list = ListView.builder(
      itemCount: hits.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              t.bookshelf.searchFolderResultCount(count: hits.length),
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          );
        }
        return _buildSearchResultTile(hits[index - 1], terms, theme);
      },
    );
    if (widget.multiSelect) return list;
    return RadioGroup<String>(
      groupValue: _selectedPaths.singleOrNull,
      onChanged: (value) {
        if (value != null) _togglePath(value);
      },
      child: list,
    );
  }

  /// 名称前缀命中优先，其次名称包含，最后是只命中路径的。
  int _searchRank(String name, String firstTerm) {
    final lower = name.toLowerCase();
    if (lower.startsWith(firstTerm)) return 0;
    if (lower.contains(firstTerm)) return 1;
    return 2;
  }

  Widget _buildSearchResultTile(
    _FolderSearchHit hit,
    List<String> terms,
    ThemeData theme,
  ) {
    final syncId = hit.folder.syncId;
    final isCurrent =
        widget.currentSyncId != null && syncId == widget.currentSyncId;
    final isForbidden = isCurrent || widget.disabledSyncIds.contains(syncId);
    final selected = _selectedPaths.contains(hit.path) && !isForbidden;
    final parentPath = _parentPathLabel(hit.path);

    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        Icons.folder_rounded,
        color: isForbidden
            ? theme.disabledColor
            : theme.colorScheme.primary,
      ),
      title: isForbidden
          ? Text(
              hit.folder.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: theme.disabledColor),
            )
          : Text.rich(
              TextSpan(
                children: _highlightSpans(hit.folder.name, terms, theme),
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
      subtitle: Text.rich(
        TextSpan(children: _highlightSpans(parentPath, terms, theme)),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.outline,
        ),
      ),
      trailing: widget.multiSelect
          ? Checkbox(
              value: selected,
              onChanged: isForbidden ? null : (_) => _togglePath(hit.path),
            )
          : Radio<String>(value: hit.path, enabled: !isForbidden),
      enabled: !isForbidden,
      onTap: isForbidden ? null : () => _togglePath(hit.path),
    );
  }

  /// 搜索结果的二级标题：显示父级路径，顶层文件夹显示「根目录」。
  String _parentPathLabel(String path) {
    final index = path.lastIndexOf('/');
    if (index <= 0) return t.common.root;
    return path.substring(0, index);
  }

  Widget _buildEmptyResult() {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.search_off,
            size: 48,
            color: theme.colorScheme.outline,
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              t.bookshelf.noFolderMatch,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 把命中搜索词的片段拆成高亮 [TextSpan]。
  List<InlineSpan> _highlightSpans(
    String text,
    List<String> terms,
    ThemeData theme,
  ) {
    final mask = buildFolderSearchHighlightMask(text, terms);
    if (!mask.contains(true)) return [TextSpan(text: text)];

    final highlightStyle = TextStyle(
      color: theme.colorScheme.primary,
      fontWeight: FontWeight.w600,
    );
    final spans = <InlineSpan>[];
    var start = 0;
    while (start < text.length) {
      final highlighted = mask[start];
      var end = start + 1;
      while (end < text.length && mask[end] == highlighted) {
        end++;
      }
      spans.add(
        TextSpan(
          text: text.substring(start, end),
          style: highlighted ? highlightStyle : null,
        ),
      );
      start = end;
    }
    return spans;
  }
}

class _FolderSearchHit {
  const _FolderSearchHit({required this.folder, required this.path});

  final ComicFolder folder;
  final String path;
}

Future<String?> _askFolderName(BuildContext context) {
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (dialogContext) {
      return AlertDialog(
        title: Text(t.bookshelf.createFolder),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: t.bookshelf.folderName),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(t.common.cancel),
          ),
          TextButton(
            onPressed: () {
              final text = controller.text.trim();
              if (text.isNotEmpty) Navigator.of(dialogContext).pop(text);
            },
            child: Text(t.common.ok),
          ),
        ],
      );
    },
  ).whenComplete(controller.dispose);
}

class _RootTargetTile extends StatelessWidget {
  const _RootTargetTile({
    required this.selected,
    required this.enabled,
    required this.onTap,
    this.singleValue,
  });

  final bool selected;
  final bool enabled;
  final VoidCallback onTap;
  final String? singleValue;

  @override
  Widget build(BuildContext context) {
    final value = singleValue;
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: const SizedBox(width: 48),
      title: Text(t.common.root),
      trailing: value == null
          ? Checkbox(
              value: selected,
              onChanged: enabled ? (_) => onTap() : null,
            )
          : Radio<String>(value: value, enabled: enabled),
    );
  }
}

class FolderNode {
  final ComicFolder folder;
  final List<FolderNode> children;

  FolderNode(this.folder) : children = [];
}

List<FolderNode> buildFolderForest(
  List<ComicFolder> folders,
  Map<String, String> pathMap,
) {
  final sorted = folders.toList()
    ..sort(
      (a, b) => (pathMap[a.syncId] ?? '').compareTo(pathMap[b.syncId] ?? ''),
    );
  final map = <String, FolderNode>{};
  final roots = <FolderNode>[];
  for (final folder in sorted) {
    final node = FolderNode(folder);
    map[folder.syncId] = node;
    final parentSyncId = folder.parentSyncId;
    if (parentSyncId == null || parentSyncId.isEmpty) {
      roots.add(node);
    } else {
      map[parentSyncId]?.children.add(node);
    }
  }
  return roots;
}

Map<String, ComicFolder> buildFolderSyncIdMap(ComicFolderType type) {
  final allFolders = ComicFolderService.listAllFolders(type);
  return {for (final folder in allFolders) folder.syncId: folder};
}

void collectForbiddenSyncIds(
  String syncId,
  List<ComicFolder> allFolders,
  Set<String> result,
) {
  if (!result.add(syncId)) return;
  for (final child in allFolders) {
    if (child.parentSyncId == syncId) {
      collectForbiddenSyncIds(child.syncId, allFolders, result);
    }
  }
}

Widget buildFolderTreeTile({
  required BuildContext context,
  required FolderNode node,
  required Map<String, String> pathMap,
  required Set<String> expandedPaths,
  required Set<String> forbiddenSyncIds,
  required Set<String> selectedPaths,
  bool singleSelect = false,
  String? currentSyncId,
  required ValueChanged<String> onToggleExpand,
  required ValueChanged<String> onSelect,
}) {
  final path = pathMap[node.folder.syncId] ?? '/${node.folder.name}';
  final syncId = node.folder.syncId;
  final isExpanded = expandedPaths.contains(path);
  final isCurrentPath = currentSyncId != null && syncId == currentSyncId;
  final isForbidden = isCurrentPath || forbiddenSyncIds.contains(syncId);
  final hasChildren = node.children.isNotEmpty;
  final theme = Theme.of(context);
  final isSelected = selectedPaths.contains(path) && !isForbidden;

  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: hasChildren
            ? IconButton(
                icon: Icon(
                  isExpanded ? Icons.expand_more : Icons.chevron_right,
                ),
                onPressed: () => onToggleExpand(path),
              )
            : const SizedBox(width: 48),
        title: Text(
          node.folder.name,
          style: isForbidden ? TextStyle(color: theme.disabledColor) : null,
        ),
        trailing: singleSelect
            ? Radio<String>(value: path, enabled: !isForbidden)
            : Checkbox(
                value: isSelected,
                onChanged: isForbidden ? null : (_) => onSelect(path),
              ),
        onTap: isForbidden ? null : () => onSelect(path),
      ),
      if (isExpanded)
        Padding(
          padding: const EdgeInsets.only(left: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: node.children
                .map(
                  (child) => buildFolderTreeTile(
                    context: context,
                    node: child,
                    pathMap: pathMap,
                    expandedPaths: expandedPaths,
                    forbiddenSyncIds: forbiddenSyncIds,
                    selectedPaths: selectedPaths,
                    singleSelect: singleSelect,
                    currentSyncId: currentSyncId,
                    onToggleExpand: onToggleExpand,
                    onSelect: onSelect,
                  ),
                )
                .toList(),
          ),
        ),
    ],
  );
}
