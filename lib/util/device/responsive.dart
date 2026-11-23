import 'dart:ui';

import 'package:material_ui/material_ui.dart';

/// 检查当前设备是否为平板。
bool isTablet(BuildContext context) {
  // 只订阅 size，避免键盘弹起（viewInsets 变化）触发全量 rebuild，见 flutter/flutter#163516
  final double shortestSide = MediaQuery.sizeOf(context).shortestSide;

  // Material Design 推荐的平板断点。
  const double tabletBreakpoint = 600.0;

  return shortestSide >= tabletBreakpoint;
}

/// 在 runApp 之前检查当前设备是否为平板。
bool isTabletWithOutContext() {
  final view = PlatformDispatcher.instance.views.first;
  final shortestSide = view.physicalSize.shortestSide / view.devicePixelRatio;

  const double tabletBreakpoint = 600.0;

  return shortestSide >= tabletBreakpoint;
}

/// 在 runApp 之前检查当前是否为横屏。
bool isLandscapeWithOutContext() {
  final view = PlatformDispatcher.instance.views.first;

  return view.physicalSize.width > view.physicalSize.height;
}
