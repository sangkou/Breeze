# OHOS-only 构建辅助

本目录只保留无法用 pub 或应用内通道替代的构建辅助代码。

## ohos_stubs/window_manager, screen_retriever, tray_manager

- 桌面栈（`window_manager 0.7` / `screen_retriever 0.4` / `tray_manager 0.8.3`）
  依赖 `nativeapi 0.6`，后者要求 Dart `^3.14`，OHOS fork 只有 3.13。
- 这三个目录是 no-op stub，只实现 `lib/` 里实际用到的 API（窗口事件、
  `Window`、`DisplayManager`、托盘 `TrayIcon`/`Menu`/`MenuItem`）。
- 调用点都被 `Platform.isWindows/isLinux/isMacOS` 挡住，OHOS 不会执行；
  stub 只保证编译。
- 仅在 `build_ohos.dart --hap` 的临时 pubspec 中通过 `dependency_overrides`
  生效；官方构建继续用 pub 版本。

## OHOS 平台插件已并入应用

`path_provider`、`shared_preferences`、`file_selector` 的 OHOS 平台实现
已迁到：

- Dart：`lib/util/ohos/path_provider.dart`、
  `lib/util/ohos/shared_preferences.dart`、`lib/util/ohos/file_selector.dart`
- ArkTS：`ohos/entry/src/main/ets/plugins/`
- 注册：`lib/util/ohos/platform_plugins.dart`，在 `main.dart` 启动最早期调用

不再需要独立 OHOS 模块、path 依赖或 `dart_plugin_registrant` 注入。

## 已迁出的纯 Dart fork

`material_ui` / `cupertino_ui` / `easy_refresh` 需要补 `TargetPlatform.ohos`
分支，无法用平台插件解决，已迁到独立仓库：

- https://github.com/deretame/material_ui_ohos （tag `ohos-1.11.1`）
- https://github.com/deretame/cupertino_ui_ohos （tag `ohos-1.1.7`）
- https://github.com/deretame/easy_refresh_ohos （tag `ohos-4.0.0`）

`build_ohos.dart --hap` 通过 git `dependency_overrides` 按 tag 拉取；
官方 Flutter 构建仍用 pub 版本。
