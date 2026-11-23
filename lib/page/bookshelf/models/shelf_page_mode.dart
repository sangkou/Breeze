import 'package:zephyr/object_box/model.dart';

enum ShelfPageMode { favorite, history, download }

ComicFolderType comicFolderTypeOf(ShelfPageMode mode) {
  return switch (mode) {
    ShelfPageMode.favorite => ComicFolderType.favorite,
    ShelfPageMode.history => ComicFolderType.history,
    ShelfPageMode.download => ComicFolderType.download,
  };
}
