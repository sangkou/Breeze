import 'package:material_ui/material_ui.dart';
import 'package:zephyr/i18n/strings.g.dart';
import 'package:zephyr/object_box/model.dart';
import 'package:zephyr/page/bookshelf/service/folder_cover_service.dart';
import 'package:zephyr/widgets/comic_simplify_entry/comic_simplify_entry_info.dart';
import 'package:zephyr/widgets/comic_simplify_entry/cover.dart';

/// 封面选择结果。
class FolderCoverChoice {
  const FolderCoverChoice.auto() : info = null;
  const FolderCoverChoice.comic(ComicSimplifyEntryInfo this.info);

  /// null 表示恢复「自动」：取文件夹里最新加入的一本漫画。
  final ComicSimplifyEntryInfo? info;
}

/// 文件夹封面选择弹窗：列出文件夹里的漫画与「自动」选项。
///
/// 返回 null 表示取消。
Future<FolderCoverChoice?> showFolderCoverPicker(
  BuildContext context, {
  required ComicFolder folder,
}) async {
  final comics = await FolderCoverService.instance.comicsInFolder(folder);
  if (!context.mounted) return null;
  final current = FolderCoverService.instance.overrideFor(folder.syncId);

  return showDialog<FolderCoverChoice>(
    context: context,
    builder: (dialogContext) {
      return AlertDialog(
        title: Text(t.bookshelf.changeFolderCover),
        content: SizedBox(
          width: 340,
          height: 400,
          child: comics.isEmpty
              ? Center(
                  child: Text(
                    t.bookshelf.folderCoverEmpty,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: comics.length + 1,
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      return ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Container(
                          width: 40,
                          height: 54,
                          decoration: BoxDecoration(
                            color: Theme.of(
                              context,
                            ).colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Icon(
                            Icons.autorenew_rounded,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                        title: Text(t.bookshelf.folderCoverAuto),
                        trailing: current == null
                            ? const Icon(Icons.check_rounded)
                            : null,
                        onTap: () => Navigator.of(
                          dialogContext,
                        ).pop(const FolderCoverChoice.auto()),
                      );
                    }
                    final info = comics[index - 1];
                    final selected =
                        current != null &&
                        current.id == info.id &&
                        current.from == info.from;
                    return ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: CoverWidget(
                        fileServer: info.fileServer,
                        path: info.path,
                        id: info.id,
                        pictureType: info.pictureType,
                        from: info.from,
                        width: 40,
                        height: 54,
                      ),
                      title: Text(
                        info.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: selected
                          ? const Icon(Icons.check_rounded)
                          : null,
                      onTap: () => Navigator.of(
                        dialogContext,
                      ).pop(FolderCoverChoice.comic(info)),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(t.common.cancel),
          ),
        ],
      );
    },
  );
}
