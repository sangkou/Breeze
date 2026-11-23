// OHOS-only no-op stub for window_manager 0.7.
//
// OHOS 不跑桌面窗口逻辑（调用点都被 Platform.isWindows/isLinux/isMacOS
// 包住），但 lib/main.dart 等文件在编译期需要这些符号。
// 官方构建仍使用 pub 的真实 window_manager。
library;

import 'dart:ffi' show Pointer, Void;
import 'dart:ui' show Color, Offset, Size;

class ListenerId {
  const ListenerId();
}

enum TitleBarStyle { normal, hidden }

sealed class WindowEvent {
  const WindowEvent();
}

class WindowResizedEvent extends WindowEvent {
  const WindowResizedEvent();
}

class WindowMovedEvent extends WindowEvent {
  const WindowMovedEvent();
}

class WindowMaximizedEvent extends WindowEvent {
  const WindowMaximizedEvent();
}

class WindowRestoredEvent extends WindowEvent {
  const WindowRestoredEvent();
}

class WindowFocusedEvent extends WindowEvent {
  const WindowFocusedEvent();
}

class CloseRequest {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;
}

class WindowCloseRequestedEvent extends WindowEvent {
  const WindowCloseRequestedEvent(this.request);

  final CloseRequest request;
}

class Window {
  Window._();

  static Window? createWithNativeWindow(Pointer<Void> handle) => null;

  String get title => '';

  bool get isMaximized => false;

  bool get isMinimized => false;

  bool get isFullScreen => false;

  set isFullScreen(bool value) {}

  NativeSize get size => const NativeSize();

  NativeOffset get position => const NativeOffset();

  ListenerId addListener(void Function(WindowEvent event) listener) =>
      const ListenerId();

  void removeListener(ListenerId id) {}

  set titleBarStyle(TitleBarStyle style) {}

  set isWindowControlButtonsVisible(bool value) {}

  set backgroundColor(Pointer<Void> color) {}

  set isVisibleInTaskbar(bool value) {}

  void setSize(Pointer<Void> size, bool animate) {}

  set position(Pointer<Void> position) {}

  void center() {}

  void maximize() {}

  void unmaximize() {}

  void minimize() {}

  void restore() {}

  void show() {}

  void hide() {}

  void startDragging() {}

  void focus() {}

  void close() {}
}

class NativeSize {
  const NativeSize();

  Size toSize() => Size.zero;
}

class NativeOffset {
  const NativeOffset();

  Offset toOffset() => Offset.zero;
}

class WindowManager {
  WindowManager._();

  static final WindowManager instance = WindowManager._();

  Window? getCurrent() => null;

  List<Window> getAll() => const <Window>[];
}

extension ColorNative on Color {
  Pointer<Void> toNative() => Pointer<Void>.fromAddress(0);
}

extension SizeNative on Size {
  Pointer<Void> toNative() => Pointer<Void>.fromAddress(0);
}

extension OffsetNative on Offset {
  Pointer<Void> toNative() => Pointer<Void>.fromAddress(0);
}
