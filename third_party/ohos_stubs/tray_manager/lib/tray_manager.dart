// OHOS-only no-op stub for tray_manager 0.8.3.
//
// 托盘初始化本身被 Platform.isWindows/isLinux/isMacOS 挡住；这里只提供
// 编译期符号，避免 OHOS 依赖树拉入 nativeapi/Dart 3.14 限制。
library;

class ListenerId {
  const ListenerId();
}

class Image {
  Image._();

  static Image? fromFile(String path) => null;

  void dispose() {}
}

class ImageAsset {
  ImageAsset._();

  static Image? fromAsset(String path) => null;
}

sealed class TrayIconEvent {
  const TrayIconEvent();
}

class TrayIconClickedEvent extends TrayIconEvent {
  const TrayIconClickedEvent();
}

class TrayIconRightClickedEvent extends TrayIconEvent {
  const TrayIconRightClickedEvent();
}

class TrayIconDoubleClickedEvent extends TrayIconEvent {
  const TrayIconDoubleClickedEvent();
}

sealed class MenuItemEvent {
  const MenuItemEvent();
}

class MenuItemClickedEvent extends MenuItemEvent {
  const MenuItemClickedEvent();
}

enum MenuItemType { normal, separator, submenu }

class TrayIcon {
  TrayIcon._();

  static TrayIcon? create() => null;

  set icon(Image image) {}

  void setVisible(bool visible) {}

  void setContextMenu(Menu menu) {}

  void setTooltip(String tooltip) {}

  void setToolTip(String tooltip) {}

  void openContextMenu() {}

  ListenerId addListener(void Function(TrayIconEvent event) listener) =>
      const ListenerId();

  void removeListener(ListenerId id) {}

  void dispose() {}
}

class Menu {
  Menu._();

  static Menu? create() => null;

  void addItem(MenuItem item) {}

  void addSeparator() {}
}

class MenuItem {
  MenuItem._();

  static MenuItem? createWithLabelAndType(String label, MenuItemType type) =>
      null;

  ListenerId addListener(void Function(MenuItemEvent event) listener) =>
      const ListenerId();

  void removeListener(ListenerId id) {}
}

class TrayManager {
  TrayManager._();

  static final TrayManager instance = TrayManager._();

  List<TrayIcon> getAll() => const <TrayIcon>[];
}
