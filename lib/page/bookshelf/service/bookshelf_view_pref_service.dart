import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:zephyr/main.dart';
import 'package:zephyr/page/bookshelf/models/shelf_page_mode.dart';
import 'package:zephyr/util/storage/get_path.dart';

/// 书架显示偏好，目前只有「不显示文件夹」。
///
/// 独立存成 `<files>/bookshelf_view_pref.json`：GlobalSetting 是 freezed 生成的，
/// 加字段要跑 build_runner，这里避开生成代码。
class BookshelfViewPrefService extends ChangeNotifier {
  BookshelfViewPrefService._();

  static final BookshelfViewPrefService instance =
      BookshelfViewPrefService._();

  static const String _fileName = 'bookshelf_view_pref.json';

  final Set<String> _hiddenFolderModes = <String>{};
  Future<void>? _loading;
  bool _loaded = false;

  bool get isLoaded => _loaded;

  Future<void> ensureLoaded() {
    if (_loaded) return Future<void>.value();
    return _loading ??= _load();
  }

  /// 该页面是否隐藏文件夹。
  bool hideFolders(ShelfPageMode mode) =>
      _hiddenFolderModes.contains(mode.name);

  Future<void> setHideFolders(ShelfPageMode mode, bool value) async {
    if (hideFolders(mode) == value) return;
    if (value) {
      _hiddenFolderModes.add(mode.name);
    } else {
      _hiddenFolderModes.remove(mode.name);
    }
    notifyListeners();
    await _save();
  }

  Future<void> _load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return;
      final hidden = decoded['hideFolders'];
      if (hidden is List) {
        final validModes = ShelfPageMode.values.map((mode) => mode.name).toSet();
        _hiddenFolderModes.addAll(
          hidden.whereType<String>().where(validModes.contains),
        );
      }
    } catch (e) {
      logger.e(e);
    } finally {
      _loaded = true;
      _loading = null;
      notifyListeners();
    }
  }

  Future<void> _save() async {
    try {
      final file = await _file();
      await file.writeAsString(
        jsonEncode({'hideFolders': _hiddenFolderModes.toList()}),
      );
    } catch (e) {
      logger.e(e);
    }
  }

  Future<File> _file() async {
    final dir = await getFilePath();
    return File(p.join(dir, _fileName));
  }
}
