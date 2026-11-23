// OHOS-only no-op stub for screen_retriever 0.4.
//
// 只在桌面窗口逻辑里使用；OHOS 不执行该路径，但窗口位置校验代码需要类型。
library;

import 'dart:ui' show Rect;

class Rectangle {
  const Rectangle();

  Rect toRect() => Rect.zero;
}

class Display {
  const Display();

  Rectangle get workArea => const Rectangle();
}

class DisplayManager {
  DisplayManager._();

  static final DisplayManager instance = DisplayManager._();

  List<Display> getAll() => const <Display>[];
}
