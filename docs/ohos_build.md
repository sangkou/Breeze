# Breeze OpenHarmony（OHOS）构建

> 状态：完整 `lib/main.dart`、插件运行时、系统桥、导入导出与通知已适配；
> 当前只在模拟器验证，零售机仍需华为签名 profile。

## 1. 工具链

| 组件 | 版本/位置 |
| --- | --- |
| Flutter OH | `flutter_flutter` `3.47.7+ohos-0.0.1-pre`（Dart 3.13.5） |
| DevEco Studio | 26（自带 OpenHarmony SDK 26、ohpm、hvigor、node、JDK） |
| OpenHarmony SDK | `C:\Program Files\Huawei\DevEco Studio\sdk`（建议用无空格 junction 指向） |
| Rust | `rust/rust-toolchain.toml` 固定 1.96.1，已包含三个 `*-linux-ohos` target |

环境变量：

```bat
set OHOS_SDK_NATIVE=D:\ohos-sdk\default\openharmony\native
set DEVECO_SDK_HOME=D:\ohos-sdk
set TOOL_HOME=C:\Program Files\Huawei\DevEco Studio
set OHOS_FLUTTER=D:\flutter_flutter
set PUB_CACHE=D:\pub_cache_ohos
```

SDK 路径不能含空格：`RUSTFLAGS` / `BINDGEN_EXTRA_CLANG_ARGS` 按空白切分。
`D:\ohos-sdk` 是指向 DevEco `sdk` 目录的 junction。

## 2. 构建

```bash
# 环境 + Rust target + ohos/ 模块检查
dart ./script/build/build_ohos.dart --check

# 交叉编译 Rust（release + strip，约 30 MB）
dart ./script/build/build_ohos.dart --rust

# Rust + 拷贝 .so + 构建 HAP（默认入口 lib/main.dart）
dart ./script/build/build_ohos.dart --hap

# 轻量启动冒烟（不初始化数据库/插件/Rust）
dart ./script/build/build_ohos.dart --hap --entry tool/ohos/smoke.dart

# release Rust 也输出 debug 级日志
dart ./script/build/build_ohos.dart --hap --rust-log
```

`--hap` 的顺序：`cargo build --target aarch64-unknown-linux-ohos` → `llvm-strip --strip-unneeded` → 拷贝到
`ohos/entry/libs/arm64-v8a/libwindcore.so` → `flutter build hap --target-platform ohos-arm64`。

OHOS fork 只有 Dart 3.13，桌面栈（`window_manager` / `tray_manager` / `screen_retriever` → `nativeapi 0.6`）
要求 `^3.14`。`--hap` 会检测 Dart 版本并**临时移除**这三个依赖，构建结束（含失败/异常）后恢复
`pubspec.yaml` / `pubspec.lock`，备份在 `.dart_tool/ohos_pub_backup/`。恢复后的 lock mtime 晚于
OHOS 的 `package_config.json`，下一次 Flutter 构建会自动重新 `pub get`。

未配置签名时 hvigor 仍会产出未签名包：
`ohos/entry/build/default/outputs/default/entry-default-unsigned.hap`（内含 `libs/arm64-v8a/libwindcore.so`）。
安装前需要在 DevEco 里配置调试签名。

## 3. 为什么不用 native assets

`native_toolchain_rust` / `code_assets` 没有可靠的 OHOS 映射，FRB 官方 OHOS 基线也要求走 CargoKit。
因此 `hook/build.dart` 对 `targetOS.name == 'ohos'` 直接返回，不产出 `CodeAsset`；
`libwindcore.so` 由构建脚本预编译并放进 HAP 的 `libs/arm64-v8a/`。
FRB 2.13 的 loader 在 `Platform.operatingSystem == 'ohos'` 时执行 `DynamicLibrary.open('libwindcore.so')`。

CMake 必须用 Ninja 生成器（`aws-lc-sys` 在 Windows 默认选 Visual Studio 会拿 `cl.exe` 编译 OHOS 目标）。
`script/build/ohos_env.dart` 会注入 `CMAKE_GENERATOR=Ninja`，脚本启动前会检查 `ninja` 是否在 PATH。

## 4. 日志

- Dart：`--dart-define=rust_log=true` 可在 release 打开 Rust 日志（`enableRustLog` 是运行时开关，代码始终编进产物）。
- Dart 未捕获异常：OHOS 不初始化 Sentry，启动早期会创建独立日志器，只把
  `FlutterError.onError` / `PlatformDispatcher.onError` / 初始化失败写入
  `<files>/log/uncaught.log`（后台 isolate 队列写入，超过 2 MB 轮转为 `.1`）。
  普通业务 logger 不落盘，避免账号密码等参数进入文件。进程被立即杀死时队列尾部
  可能丢失，属于 best-effort。拉取示例：
  `hdc file recv /data/app/el2/100/base/com.zephyr.breeze.ohos/files/log/uncaught.log .`
- Rust 级别：`RUST_LOG` 优先；否则默认 `debug`，并静音 hickory / reqwest / h2 噪音。
- OHOS sink：`rust/src/api/logger.rs` 的 `HilogMakeWriter` 调用 `OH_LOG_Print`（`libhilog_ndk.z.so`），
  真机用 `hdc shell hilog | grep windcore` 查看。
- **Windows 编码坑**：日志本身是 UTF-8，但 `hdc shell` 直接输出到 Windows 控制台时可能按 GBK
  解码，中文和 `│`/`─` 会显示成 `鍛ㄤ簲`、`鈹€`。先把日志重定向到文件再用 UTF-8 打开，或先执行
  `chcp 65001`；不要据此判断 Rust 日志损坏。
- 第三方 `log` 门面记录默认封顶 `Info`，只有显式 `RUST_LOG` 才放开 debug。

## 5. UI 包 fork

`material_ui 1.11.1` / `cupertino_ui 1.1.7` 对 `TargetPlatform` 做穷举 switch，
OHOS fork 新增 `TargetPlatform.ohos` 后编译失败。仓库内维护了 OHOS 专用 fork：


补丁内容只是把 `ohos` 并入 Android 分支（行为暂按 Android）。
`build_ohos.dart --hap` 在临时 pubspec 里注入 `dependency_overrides`，
构建结束恢复；官方构建继续用 pub 版本。详见 `third_party/README.md`。

已验证：默认入口 `lib/main.dart` 能编译并产出完整 debug HAP
（`entry-default-unsigned.hap`，约 227 MB）；`tool/ohos/smoke.dart` 仍可用于
不依赖业务初始化的轻量启动验证。

桌面栈 `window_manager` / `screen_retriever` / `tray_manager` 依赖
`nativeapi 0.6`（Dart `^3.14`）。OHOS 构建期间用
`third_party/ohos_stubs/*` 的 no-op stub 覆盖它们；这些路径在 OHOS 上不会执行，
stub 只提供编译期符号。

Flutter 3.47/3.50 API 差异：
- `Image.useLogicalCacheSize`（3.50）在 OHOS fork 不存在，已移除；
- `ScrollCacheExtent`/`scrollCacheExtent`（3.50）改用两端都有的
  `cacheExtent`（3.50 标记 deprecated，已 ignore）。

## 6. 签名与安装（本地 CLI）

```bash
# 签名 + 安装到模拟器（自动读取 UDID）
dart ./script/build/sign_ohos_hap.dart \
  --hap ohos/entry/build/default/outputs/default/entry-default-unsigned.hap \
  --device 127.0.0.1:5555 --install
```

- 默认使用 SDK 自带 `OpenHarmony.p12`（密码 `123456`）+ 调试 profile 模板 +
  `hap-sign-tool.jar`，不需要华为账号；已验证 HarmonyOS 26 模拟器可安装。
- 调试 profile 会绑定 `hdc shell bm get --udid` 读到的设备 UDID，只对这台设备有效。
- **HarmonyOS 零售机不一定信任 OpenHarmony 测试证书**：让用户侧载需要华为签发的
  debug profile（限制设备数）或 release 证书/profile（AGC 开发者账号），
  不存在 Android 那种“未签名/自签名随便装”的路径。
- 模拟器是 x86_64：用 `build_ohos.dart --arch x64` 构建（arm64 包会报
  `install parse native so failed`）。

## 7. 平台实现（path_provider / shared_preferences / file_selector）

- OHOS 平台实现已全部并入应用，不再有 `third_party/ohos_plugins/` 或独立
  OHOS 模块：
  - Dart：`lib/util/ohos/path_provider.dart`、
    `lib/util/ohos/shared_preferences.dart`、`lib/util/ohos/file_selector.dart`
  - ArkTS：`ohos/entry/src/main/ets/plugins/OhosPathProvider.ets`、
    `OhosSharedPreferences.ets`
  - 注册：`lib/util/ohos/platform_plugins.dart`，在 `main.dart` 的
    `ensureInitialized()` 之后立刻调用。
- `build_ohos.dart --hap` 不再注入 `*_ohos` path 依赖；只需要 UI fork 与
  桌面 stub 的依赖覆盖。
- 偏好存储沿用旧插件文件名 `FlutterSharedPreferences` 与 key 格式，
  升级后已有设置不丢；写偏好失败也不会阻塞插件首页切换。
- 探针 `tool/ohos/runtime_probe.dart` 已验证：FRB 加载、Rust greet、
  `getApplicationSupportDirectory`（`/data/storage/el2/base/files`）、
  `getTemporaryDirectory`、`Database.open` + `SELECT 1` 全部通过。
- 完整 `lib/main.dart` 已在模拟器启动并显示 Home/书架/发现/更多底栏。

### OHOS libc 缺 robust mutex 符号

`pthread_mutex_consistent` / `pthread_mutexattr_setrobust` 在 OHOS libc 中不存在，
LMDB 默认启用 robust mutex，导致 `libwindcore.so` 加载时报
`symbol not found`。`ohos_env.dart` 已给 C 编译加 `-DMDB_USE_ROBUST=0`
（只做只读 ObjectBox 遗留导入，不需要 robust）。

### 模拟器 Impeller

HarmonyOS 模拟器上 Impeller 会白屏。`--hap` 加 `--no-impeller` 可临时把
`buildinfo.json5` 的 `enable_impeller` 改为 false（构建后恢复）；真机可保持默认 true。

## 8. 平台能力适配

- **Sentry**：OHOS 不初始化（`isOhos` 分支直接走无 Sentry 的启动路径），
  避免 native 传输缺失导致事件静默丢失。
- **WebView**：`lib/page/webview_page.dart` 在 OHOS 显示“暂不支持内置网页视图”页面，
  不构建 `InAppWebView`；页面提供“外部浏览器打开”按钮，复用系统 `startAbility`。
- **超分**：`GlobalSettingPage` 在 OHOS 直接隐藏 RealSR 入口（`isOhos` 时 future=false）。
- **保存到相册**：`zephyr/ohos_file` 通道 + `photoAccessHelper.showAssetsCreationDialog`，
  已验证弹出“允许 Breeze 保存 1 张图片?”系统确认框。
- **打开文件**：`openFileWithSystem` → OHOS `startAbility(action.viewData)`；
  其他平台仍走 `open_file` 插件。
- **文件选择**：`lib/util/ohos/file_selector.dart` 直接实现
  `FileSelectorPlatform`，底层复用 `BreezeOhosPlugin` 的 `DocumentViewPicker`。
  选中的文件复制到应用缓存，导出走系统“另存为”后原生复制到用户选择的 URI。
- **通知权限**：`notificationManager.isNotificationEnabled/requestEnableNotification`，
  启动时弹系统授权；`flutter_local_notifications` 在 OHOS 不初始化。
- **系统通知发布**：`BreezeOhosPlugin.publishNotification` 使用
  `notificationManager.publish` + `WantAgent`（点击拉起 EntryAbility），
  下载完成/追更通知已接入；probe 验证通知中心可见。
- **应用版本**：OHOS 从 `bundleManager.getBundleInfoForSelfSync` 读取，
  避免 `package_info_plus` 缺失导致备份导出失败；插件字节码缓存也改用该桥，
  不再回退成 `unknown`。包内 `versionName` / `versionCode` 以 `pubspec.yaml`
  的 `version: x.y.z+build` 为准：`build_ohos.dart --hap` 会先同步
  `ohos/AppScope/app.json5`，Flutter 再用 `ohos/local.properties` +
  flutter-hvigor-plugin 覆盖一遍。直接用 DevEco / `hvigorw` 打包时不经过
  Flutter 覆盖，`app.json5` 的值就是最终值，所以不要在 `app.json5` 里手写版本。
- **设备信息**：`BreezeOhosPlugin.getDeviceInfo` 读取 `@ohos.deviceInfo`
  （品牌、厂商、型号、系统版本、SDK、ABI）；更新页的架构判断已接入。
- **打开链接**：`lib/util/system/external_link.dart` 在 OHOS 走
  `startAbility(action.viewData)`，其他平台继续 `url_launcher`；关于页、插件页、
  更新日志、WebView 外链均使用该入口。
- **网络状态**：`getConnectivity` 读取 `@ohos.net.connection` 默认网络与
  `bearerTypes`；阅读器状态栏在 OHOS 每 5 秒刷新一次（需要
  `ohos.permission.GET_NETWORK_INFO`）。
- **电池状态**：`getBatteryInfo` 读取 `@ohos.batteryInfo` 的电量与充电状态；
  阅读器状态栏同样每 5 秒刷新。`battery_plus` / `connectivity_plus` 在 OHOS 不会被调用。
- **下载与保活**：OHOS 只支持前台下载，不申请持续任务（ContinuousTask）或
  后台保活；退到后台后的下载由系统调度，可能暂停。后台保活开关和
  `flutter_foreground_task` 仍为 Android 专属。
- **动态取色**：OHOS 隐藏设置开关，并绕过 `DynamicColorBuilder`，始终使用种子色。
- **本地权限**：`module.json5` 目前声明 `INTERNET` 与 `GET_NETWORK_INFO`；
  通知通过 `requestEnableNotification` 在运行时申请，不额外声明系统级权限。
- **音量键翻页**：已适配。复用 `volume_key_handler` / `volume_key_events` 通道，
  ArkTS 侧用 `inputConsumer.on('keyPressed')` 监听 `KEYCODE_VOLUME_UP/DOWN`；
  阅读器启用拦截时会同时屏蔽系统音量调节，退出阅读器后恢复。
  已在模拟器用 `uitest uiInput keyEvent 16/17` 验证（probe 收到 `volume_up` / `volume_down`，阅读器 3/118 → 4/118 → 3/118）。
  注意 `ReaderVolumeController.listen()` 也要放行 `isOhos`，否则会出现“系统音量被拦截但页面不翻”的现象。
  该 API 需要 API 16+，且仅在应用前台焦点窗口生效。

### 应用图标

OHOS 桌面与应用内图标来自 `asset/image/app-icon.png`，已同步到：

- `ohos/AppScope/resources/base/media/app_icon.png`
- `ohos/entry/src/main/resources/base/media/icon.png`
- `ohos/entry/src/ohosTest/resources/base/media/icon.png`

替换图标后重新构建 HAP 即可，无需改 `app.json5` / `module.json5`。

## 9. 已知障碍

### 第三方包策略

- `shared_preferences` / `path_provider` / `file_selector`：官方 Dart 包 +
  应用内平台实现（`lib/util/ohos/*.dart`），
  原生方法统一放在 `BreezeOhosPlugin`；不再有独立 OHOS 插件模块。
- `material_ui` / `cupertino_ui` / `easy_refresh`：纯 Dart 包，OHOS 下需要补
  `TargetPlatform.ohos` 分支，无法用平台插件解决。已迁到独立 GitHub 仓库，
  按 tag 作为 git 依赖注入，仓库内不再保留源码：
  - `material_ui_ohos` / `ohos-1.11.1`
  - `cupertino_ui_ohos` / `ohos-1.1.7`
  - `easy_refresh_ohos` / `ohos-4.0.0`
- `window_manager` / `screen_retriever` / `tray_manager`：OHOS 不执行桌面路径，
  只保留数 KB 的 no-op stub。
- 插件缺口：`url_launcher`、`package_info_plus`、`device_info_plus`、
  `connectivity_plus`、`battery_plus`、`dynamic_color` 在 OHOS 没有平台实现，
  已分别由 `zephyr/ohos_file` 通道或 UI 降级替代（见 §8）。
  仍有缺口：`flutter_inappwebview`（显示不支持页）、`sentry_flutter`（不初始化）、
  `flutter_foreground_task`（无 OHOS 持续任务，后台下载保活不保证）、
  `flutter_local_notifications`（仅下载完成/追更走原生通知）。
  OHOS(非 PC/2in1)系统不支持文件夹选择：批量导出自动改为 zip + 逐个系统“另存为”；
  本地文件夹导入入口隐藏，改用压缩包导入；自定义导出目录选项在 OHOS 隐藏。

### 其他已知问题

1. **Dart 版本冲突**：完整依赖树中的桌面栈（`window_manager` / `tray_manager` / `screen_retriever` → `nativeapi 0.6`）
   要求 Dart `^3.14.0`，OHOS fork 只有 3.13.5。`--hap` 已自动临时裁剪并恢复；
   长期方案仍是给 OHOS 维护独立依赖集（或等 fork 升级 Dart）。
2. **`material_ui` 的 OHOS 分支**：上游 `material_ui 1.11` 缺少
   `TargetPlatform.ohos` 分支；完整 App 已改用 `material_ui_ohos` / `cupertino_ui_ohos` fork，
   `tool/ohos/smoke.dart` 仅作为不依赖 UI fork 的轻量探针。
3. **插件适配**：`path_provider` / `shared_preferences` / `file_selector` 已有 OHOS 实现；
   `url_launcher`、`package_info_plus`、`device_info_plus`、`connectivity_plus`、
   `battery_plus`、`dynamic_color` 已由本地桥或 UI 降级覆盖。
   剩余：`sentry_flutter`、`flutter_inappwebview`、`flutter_foreground_task` 等。
4. **签名**：`ohos/build-profile.json5` 目前 `signingConfigs` 为空，需在 DevEco 里生成调试签名后才能安装；
   命令行可用 `script/build/sign_ohos_hap.dart` 签未签名 HAP。
5. `lib/main.dart` 已可在 OHOS fork 下完整构建；调试探针统一放在 `tool/ohos/`。
6. **release AOT 与 jni**：`sentry_flutter` / `path_provider_android` 会间接带入
   `package:jni 1.2.0`，其 `Int32` 的 `AbiSpecificIntegerMapping` 没有
   `ohosArm` / `ohosArm64` / `ohosX64`，release AOT 会报
   `Int32 is missing mapping for ohos_arm64`。`build_ohos.dart --hap` 会把
   `package_config.json` 中的 jni 复制到 `.dart_tool/ohos_jni_patch` 并补三个
   mapping，只在 OHOS 临时 pubspec 中 override；官方 Android/桌面构建不受影响。
7. **HAP native 压缩**：`module.json5` 设置
   `compressNativeLibs: true` + `extractNativeLibs: true`，并把
   `build-profile.json5` 的 `targetSdkVersion` 提到 `6.0.0(20)`
   （`extractNativeLibs` 从 API 20 开始支持；`compatibleSdkVersion` 保持
   `5.0.5(17)`）。HAP 从 63.8 MB 降到约 29.2 MB，native 库在安装时解压；
   release x64 包已在 API 17 模拟器安装并正常启动。只开
   `compressNativeLibs`、不配 `extractNativeLibs` 会安装成功但启动失败。
8. **pub get 覆盖**：`build_ohos.dart --hap` 会临时改写 `pubspec.yaml` 注入 OHOS override，
   这期间若有别的 Flutter（IDE 的自动 pub get、Puro 的 3.50）跑 `pub get`，会覆盖两处产物：
   `.dart_tool/package_config.json` 里 `flutter` / `sky_engine` 指回官方 SDK（AOT 报
   `Type 'ui.Hyphens' not found`），`.flutter-plugins-dependencies` 丢掉 `plugins.ohos`
   （hvigor 报 `00305010 Syntax Error` / `Cannot read properties of undefined (reading 'filter')`）。
   脚本已固定 `FLUTTER_ROOT` 指向 OHOS SDK、构建前补齐 `plugins.ohos`、并在检测到 SDK 被换掉时
   重试一次；`ohos/hvigorconfig.ts` 也把 `injectNativeModules` 包进 try/catch。
   反复失败时关闭 IDE 的自动 pub get 再构建。
