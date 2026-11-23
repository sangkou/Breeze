# Breeze — Agent 开发指南

> 本文档面向 AI 编程助手。若你第一次接触本项目，请先阅读本文件再修改代码。项目的主要注释、文档与发布日志均为中文，因此本文档也使用中文撰写。

---

## 1. 项目概述

**Breeze**（包名 `zephyr`）是一个使用 Flutter 开发的跨平台漫画阅读应用，支持第三方图源插件。当前主要支持：

- **Android**（APK 分发）
- **iOS / iPadOS**（未签名 IPA，需侧载）
- **Windows**（Inno Setup 安装包）
- **macOS**（DMG / Homebrew Cask）
- **Linux**（Flatpak）
- **HarmonyOS NEXT / OpenHarmony**（未签名 arm64 HAP，由用户自签安装；构建见 §5.4）

### 1.1 核心定位

- 应用本身不包含具体漫画内容，漫画数据通过**插件**获取。
- 插件运行在技术栈 `Dart → Flutter Rust Bridge → Rust → QuickJS` 的 Rust 侧运行时中。
- 默认内置插件（Bika、禁漫等）在 `rust/build.rs` 编译时从 CDN 下载并打包进二进制。

### 1.2 主要仓库

- **Dart/Flutter 应用**：`lib/`
- **Rust FFI 库**：`rust/`（crate 名 `windcore`）
- **QuickJS 运行时封装**：`rust/rquickjs_playground/`（独立子 crate，可整体抽离）
- **HarmonyOS 宿主工程**：`ohos/`（ArkTS 入口、`BreezeOhosPlugin`、hvigor 配置）
- **OHOS 调试探针**：`tool/ohos/`（运行期、通知、WebView、音量键等最小启动验证）
- **Windows 安装器**：`windows-installer/breeze.iss`（Inno Setup 7）
- **构建/发布脚本**：`script/`
- **CI/CD**：`.github/workflows/`

---

## 2. 技术栈

### 2.1 Flutter / Dart

- **Flutter 版本**：官方构建 `3.50.0`（通过 `.fvmrc` / `.puro.json` 锁定，建议使用 FVM / Puro）
- **OHOS Flutter**：独立 fork `flutter_flutter 3.47.7+ohos-0.0.1-pre`（Dart 3.13.5），通过 `OHOS_FLUTTER` 或 `--flutter` 指定；不要用它跑官方平台构建
- **Dart SDK**：官方 Flutter 下为 `^3.14.0`（见 `pubspec.yaml`）；OHOS fork 低于 3.14，`build_ohos.dart --hap` 会自动注入临时依赖覆盖
- **应用包名**：`zephyr`（OHOS `bundleName` 为 `com.zephyr.breeze.ohos`，与安卓版 `com.zephyr.breeze` 不同，两者可在鸿蒙设备上共存）

### 2.2 Rust

- **主库 crate**：`rust/` 下的 `windcore`
- **Rust edition**：2024
- **Rust 工具链**：由 `rust/rust-toolchain.toml` 固定为 **1.96.1**，并在该工具链下声明 Android / iOS / Windows / Linux / OHOS / macOS target；不要假设跟随系统 stable
- **Flutter Rust Bridge**：`2.13.0`（Rust 侧通过 `=2.13.0` 精确锁定）
- **rquickjs**：`0.12.0`（见 `rust/rquickjs_playground/Cargo.toml`），用于执行 JS 插件；`rquickjs-sys` 额外打了 `fix/android-windows-bindgen` 分支 patch（Windows 交叉编译 Android 时 host 侧 bindgen 误用 NDK libclang，上游 issue `#709`，见 `rust/Cargo.toml` 底部）

### 2.3 状态管理与路由

- **状态管理**：`flutter_bloc` + `bloc` + `bloc_concurrency`
  - 复杂业务使用 `Bloc`（事件驱动）
  - 轻量/局部状态使用 `Cubit`
- **路由**：`auto_route`，页面使用 `@RoutePage()` 注解

### 2.4 数据持久化与网络

- **本地数据库**：SQLite。Rust 侧 `rusqlite`（`rust/src/db/sql.rs`、`rust/src/api/database.rs`）负责连接/事务/执行，Dart 门面在 `lib/database/`（`BreezeDatabase` + 各领域 Repository）；初始化时只读导入旧 ObjectBox LMDB（`rust/src/db/obx_reader.rs`），完成后可归档 `data.mdb`
- **HTTP 客户端**：Rust `reqwest`（经 FRB 暴露为 `HttpClient` / Dart `WindHttp`）
- **图片加载/缓存**：`photo_view`
- **后台下载**：自研下载队列（`lib/service/download/`）
- **WebDAV / S3 同步**：Rust 侧 `reqwest_dav`、Dart 侧 `minio`

### 2.5 监控与异常上报

- **Sentry**：`sentry_flutter`，崩溃、性能剖析、会话回放
- 通过 `sentry_dsn` dart-define 在 Release 构建中启用
- **OHOS 不初始化 Sentry**（`main.dart` 的 `isOhos` 分支直接跳过），改用 `lib/util/error/uncaught_error_log.dart` 把未捕获异常写入 `<files>/log/uncaught.log`

---

## 3. 仓库结构

```text
.
├── lib/                        # Dart/Flutter 主代码
│   ├── main.dart               # 应用入口
│   ├── config/                 # 全局与业务配置（GlobalSetting、Bika/JM 设置等）
│   ├── cubit/                  # 全局轻量 Cubit
│   ├── debug/                  # 调试页面
│   ├── model/                  # 通用业务模型
│   ├── network/                # 网络层、插件调用、WebDAV/S3 同步
│   ├── object_box/             # 统一 JSON 数据模型（json_serializable），不再是 ObjectBox 实体
│   ├── page/                   # 页面/Feature 集合（最大模块）
│   ├── plugin/                 # 插件注册与服务
│   ├── src/rust/               # FRB 生成的 FFI 绑定
│   ├── type/                   # 通用枚举与类型工具
│   ├── util/                   # 工具类、路由、桌面端适配、下载队列等
│   │   └── ohos/               # OHOS 平台实现（path_provider / shared_preferences / file_selector / 系统桥）
│   └── widgets/                # 通用 UI 组件
├── rust/                       # Rust FFI 主库（windcore）
│   ├── src/api/                # 暴露给 Dart 的 API
│   ├── src/compressed/         # 压缩/打包（tar/zip/brotli/zstd）
│   ├── src/db/                 # SQLite（rusqlite）、旧 ObjectBox LMDB 导入与归档
│   ├── src/decode/             # 禁漫图片反混淆
│   ├── src/memory/             # 内存统计
│   ├── src/qjs/                # QuickJS runtime 管理
│   ├── build.rs                # 编译时从 CDN 下载内置插件 bundle（Bika/禁漫），失败回退缓存
│   ├── rust-toolchain.toml     # 固定 Rust 1.96.1 与各平台 target
│   ├── Cargo.toml
│   └── rquickjs_playground/    # QuickJS 宿主运行时封装 crate（独立子 crate）
├── ohos/                       # HarmonyOS NEXT 宿主工程（ArkTS Ability + BreezeOhosPlugin）
├── tool/ohos/                  # OHOS 最小运行期/系统能力探针
├── third_party/ohos_stubs/     # OHOS 构建期的桌面依赖 no-op stub
├── windows-installer/          # Windows 安装器（Inno Setup 7 脚本）
├── packages/coreml_upscale/    # CoreML 超分 Flutter 插件（iOS/macOS）
├── script/                     # build（平台构建/OHOS 签名）/ codegen（唯一代码生成入口 §5.1）/ android（waifu2x CLI 依赖链）/ models（超分模型转换）/ lint（静态检查）
├── hook/build.dart             # Dart Native Asset 构建钩子
├── flatpak/                    # Linux Flatpak 配置
├── android/                    # Android 工程
├── ios/ / macos/ / linux/ / windows/  # 各平台原生工程
├── .github/workflows/          # CI/CD
├── asset/                      # 字体、图片资源
├── lib/i18n/                   # slang 国际化（`*.i18n.json` 输入 → `strings*.g.dart` 生成）
├── lib/config/router/          # auto_route 路由定义与生成文件
├── lib/database/               # SQLite 门面、schema、迁移与各领域 Repository
├── test/                       # 单元/widget 测试（`flutter test`）
├── integration_test/           # 集成测试（Android RealSR / CoreML 超分端到端）
└── docs/                       # 设计文档（`ohos_build.md`、sync_logic、android_realsr_build 等）
```

### 3.1 典型 Feature 目录结构

`lib/page/` 下每个模块通常按职责分层：

```text
page/comic_info/
├── comic_info.dart           # barrel 文件
├── bloc/                     # BLoC（event/state）
├── cubit/                    # 可选 Cubit
├── method/                   # 业务方法
├── models/                   # 页面内模型
├── json/normal/              # JSON 数据类与反序列化
├── view/                     # 页面主体 Widget
└── widgets/                  # 页面私有组件
```

### 3.2 生成文件位置

以下文件由工具生成，**请勿手动修改**：

- **slang**：`lib/i18n/strings*.g.dart`（输入 `lib/i18n/*.i18n.json`，配置 `slang.yaml`）
- **flutter_rust_bridge**：`lib/src/rust/frb_generated*.dart`、`lib/src/rust/api/*.dart`、`rust/src/frb_generated.rs`
- **auto_route**：`lib/config/router/router.gr.dart`
- **freezed / json_serializable**：各目录下的 `*.freezed.dart`、`*.g.dart`
- **OHOS 插件注册**：`ohos/entry/src/main/ets/plugins/GeneratedPluginRegistrant.ets`（构建生成、已在 `.gitignore` 中忽略）

> `lib/object_box/model.g.dart` 现在由 `json_serializable` 生成，只承载统一数据模型；SQLite 表结构是手写 SQL（`lib/database/schema.dart`），没有 ObjectBox 代码生成。

---

## 4. 环境准备

### 4.1 必需工具链

- **Flutter SDK**：`3.50.0`（通过 `.fvmrc` 与 `.puro.json` 锁定，建议使用 FVM / Puro）；OHOS 另需 `flutter_flutter 3.47.7+ohos-0.0.1-pre`
- **Rust Toolchain**：`rust/rust-toolchain.toml` 固定 **1.96.1** 并声明各平台 target；首次构建前确认对应 target 已安装（OHOS 见 §5.4）
- **LLVM / Clang**：`rquickjs` 等库需要解析 C 头，Windows 推荐 `choco install llvm`；OHOS 交叉编译优先使用 SDK 自带 clang/libclang
- **Java 21**：Android / Windows / Linux / OHOS（hvigor）编译必需
- **Inno Setup 7**：Windows 安装器编译（`ISCC.exe`），需在 `PATH` 中或通过 `ISCC` / `INNO_SETUP_HOME` 指定
- **Android SDK / NDK**：NDK 版本见 `android/app/build.gradle.kts` 中的 `ndkVersion`
- **OHOS 工具链**：DevEco Studio 26（或 HarmonyOS Command Line Tools）+ OpenHarmony SDK + `ohpm` / `hvigorw` / `node`；Windows 上 `aws-lc-sys` 还需要 `ninja`

### 4.2 推荐环境变量

| 变量名 | 说明 | 示例 |
|--------|------|------|
| `JAVA_HOME` | 编译 Android / Windows / Linux / OHOS 必需；OHOS 未设置时脚本会回退 DevEco `jbr` | `C:\Program Files\Android\Android Studio\jbr` |
| `ANDROID_NDK_HOME` | Rust 交叉编译 Android 库必需 | `...\Android\Sdk\ndk\29.0.14206865` |
| `LIBCLANG_PATH` | 供 `bindgen` 生成 FFI 绑定使用；OHOS 构建会自动指向 SDK 的 `llvm/bin` | `C:\Program Files\LLVM\bin` |
| `ISCC` | `ISCC.exe` 完整路径（可选，优先级最高） | `C:\Program Files\Inno Setup 7\ISCC.exe` |
| `INNO_SETUP_HOME` | Inno Setup 安装目录（可选） | `C:\Program Files\Inno Setup 7` |
| `OHOS_FLUTTER` | OHOS Flutter fork 的 `bin/flutter(.bat)` 或 SDK 目录 | `D:\flutter_flutter` |
| `OHOS_SDK_NATIVE` | OpenHarmony SDK 的 `native` 目录（Rust 交叉编译最优先） | `D:\ohos-sdk\default\openharmony\native` |
| `HOS_SDK_HOME` | OHOS Flutter 查找 SDK 的根目录；缺失会报 `No Hmos SDK found`，应与 `DEVECO_SDK_HOME` 指向同一目录 | `D:\ohos-sdk` |
| `DEVECO_SDK_HOME` | DevEco SDK 根目录，脚本会尝试其下 `native/` 或 `default/openharmony/native/` | `D:\ohos-sdk` |
| `TOOL_HOME` | DevEco Studio 安装目录（寻找 `ohpm` / `hvigor` / `node` / `jbr`） | `C:\Program Files\Huawei\DevEco Studio` |
| `PUB_CACHE` | OHOS 构建建议与官方 Flutter 分开，避免 Dart 3.13/3.14 依赖缓存互踩 | `D:\pub_cache_ohos` |

确保 `PATH` 中包含 `javac`、`clang`、`ninja`。**OHOS SDK 路径不要含空格**：`RUSTFLAGS` / `BINDGEN_EXTRA_CLANG_ARGS` 按空白切分，`C:\Program Files\...` 会导致链接参数被拆散。

CI 中 `ErBWs/setup-ohos` 会提供 `HOS_SDK_HOME`；本地也必须设置它供 OHOS Flutter 使用。`build_ohos.dart` 自身只读取 `OHOS_SDK_NATIVE` / `DEVECO_SDK_HOME` / `OHOS_SDK_HOME` 来定位 Rust 工具链。

### 4.3 依赖初始化

```bash
flutter pub get
```

> Flutter 工程禁止用裸 `dart run` 执行依赖 SDK 的命令（如 `dart run slang` 会因解析不了 `integration_test` 等 SDK 内建包而失败）；一律走 `flutter` 通道（`flutter pub run …`）或 `dart ./script/*.dart`（脚本内部已自行调用 `flutter`）。Puro 用户见 §4.4。

### 4.4 Windows 下调试终端调用 Flutter / Dart（建议优先尝试）

项目使用 **Puro** 管理 Flutter SDK（`.puro.json` 锁定环境）。在 MSYS2 / Git Bash 等类 Unix Shell 中直接执行 `flutter` 或 `dart` 时，这两个脚本会调用 Windows 原生可执行文件 `puro.exe`，有时会因为路径/兼容层问题失败。

> 因此，**建议优先尝试**通过 `puro` 命令间接调用：

```bash
# 优先尝试
puro flutter --version
puro dart --version

# 示例
puro flutter pub get
puro dart ./script/codegen/code_generate.dart
```

如果当前 Shell 的 `PATH` 中没有 `puro`，可使用其绝对路径（以本机默认安装位置为例）：

```bash
/c/Users/windy/.puro/bin/puro flutter pub get
/c/Users/windy/.puro/bin/puro dart ./script/codegen/code_generate.dart
```

> 这并非强制要求。若你的终端/IDE 已能直接调用 `flutter`/`dart`，或 `cmd.exe` / PowerShell 下工作正常，继续使用原有方式即可。只有在直接调用失败时，再切换到 `puro flutter` / `puro dart`。

---

## 5. 构建与运行

### 5.1 代码生成（唯一入口）

修改以下任一输入后，**必须**运行统一脚本重新生成，禁止手动逐条执行或只跑其中某一步：

- `lib/i18n/*.i18n.json`（slang）→ `lib/i18n/strings*.g.dart`
- `@RoutePage()` / `lib/config/router/router.dart`（auto_route）、`freezed` / `json_serializable` 注解类（含 `lib/object_box/model.dart`）→ 各 `*.g.dart` / `*.freezed.dart` / `router.gr.dart`
- `rust/src/api/`、`rust/src/qjs/` 等 FRB 导出（`#[frb]`）→ `lib/src/rust/frb_generated*.dart` + `rust/src/frb_generated.rs`

```bash
dart ./script/codegen/code_generate.dart
```

脚本顺序：`flutter pub run slang` → `flutter pub run build_runner build --delete-conflicting-outputs` → 检查/安装 `flutter_rust_bridge_codegen` → `flutter_rust_bridge_codegen generate` → `dart format ./lib/` + `cargo fmt`（含 `rquickjs_playground`）。
> 注意：slang 必须走 `flutter pub run slang`，裸 `dart run slang` 在 Flutter 工程里解析依赖失败（见 §4.3）。

### 5.2 本地运行

```bash
# 调试运行
flutter run

# 带 Sentry DSN 运行
flutter run --dart-define=sentry_dsn=YOUR_DSN
```

### 5.3 平台构建

项目提供 Dart 脚本统一处理构建：

| 平台 | 构建命令/脚本 | 产物 |
|------|---------------|------|
| Android | `dart ./script/build/build_apk.dart` | `build/app/outputs/flutter-apk/*.apk` |
| Linux（Flatpak） | `dart ./script/build/build_linux_flatpak.dart` | `breeze.flatpak` |
| Linux（DEB） | `dart ./script/build/build_linux_deb.dart` | `*.deb` |
| Windows | `dart ./script/build/build_windows.dart` | `build/windows/installer/windows-installer.exe` |
| macOS | `flutter build macos --release` + `create-dmg` | `Breeze-macOS.dmg` |
| iOS | `flutter build ios --release --no-codesign` + 打包 | `Breeze-iOS.ipa` |
| HarmonyOS | `dart ./script/build/build_ohos.dart --hap` | `ohos/entry/build/default/outputs/default/entry-default-unsigned.hap` |

`build_apk.dart` 无参数时默认构建 Release 并分 ABI；带任意参数时进入快速 Debug 构建（`--debug --target-platform=android-arm64,android-x64`）。

iOS 模拟器（`aarch64-apple-ios-sim`）构建时，`rquickjs-sys` 的 bindgen 会把 Rust target triple 直接传给 clang，但 clang 不识别 `-sim` 后缀。`hook/build.dart` 已针对该目标自动注入 `BINDGEN_EXTRA_CLANG_ARGS=--target=aarch64-apple-ios-simulator` 以绕过此问题。

Windows 安装器使用 Inno Setup 7 编译：`script/build/build_windows.dart` 先构建 Flutter Windows Release，再调用 `ISCC.exe` 将 `build/windows/x64/runner/Release` 直接打包为 `build/windows/installer/windows-installer.exe`。安装脚本位于 `windows-installer/breeze.iss`，采用 LZMA2 solid 压缩，并处理旧 Tauri 安装器的卸载项迁移、运行中应用的命名管道退出与旧快捷方式清理。需本机安装 Inno Setup 7（或设置 `ISCC` / `INNO_SETUP_HOME`）。

RealSR 桌面端模型不再打包进安装包，首次使用需在设置页下载。模型下载后解压到 `getFilePath()/super_resolution/`，由 `RealSrSuperResolution` 自动调用。Linux / macOS 下载完成后会自动执行 `chmod +x` 授权。

Android 端已彻底从 JNI + ncnn 共享库方案切换到 **waifu2x CLI** 方案：APK 中以 native library 形式打包静态链接 ncnn / Vulkan / OpenCV / libwebp 的 `libwaifu2x_cli.so`；Dart 层通过 MethodChannel 获取它在 `nativeLibraryDir` 中的路径，直接通过 `Process.run` 调用。模型仍在首次使用时从 `https://github.com/deretame/breeze-binary/raw/main/realsr-android.7z` 下载并解压到 `getFilePath()/super_resolution/`。

相关脚本（默认仅 `arm64-v8a`）：

- 准备 OpenCV / libwebp 依赖：`python script/android/prepare_android_waifu2x_deps.py`
- 编译 ncnn 静态库：`python script/android/build_ncnn_static_android.py`（关闭 OpenMP，启用 Vulkan）
- 编译 waifu2x CLI：`python script/android/build_waifu2x_cli_android.py`（输出 `android/app/src/main/jniLibs/arm64-v8a/libwaifu2x_cli.so`；若 `third_party/RealSR-NCNN-Android` 不存在，脚本会自动从上游仓库克隆）

旧版 ncnn 共享库脚本 `script/build_ncnn_android.py` 与 `script/download_android_ncnn_deps.dart` 已删除（CLI 方案不再需要）；`script/models/build_android_ncnn_models.py` 打包 `realsr-android.7z` 用，但其 `model_dirs`（`models-cunet` / `models-upconv_7_photo`，缺 `models-se`）与现 `AndroidNcnnModelConfig` 已脱节，下次打模型包前需先更新。

### 5.4 鸿蒙（OpenHarmony / HarmonyOS NEXT）

完整平台适配与历史背景见 `docs/ohos_build.md`；这里只列日常构建必需信息。

**工具链**

- OHOS Flutter：`flutter_flutter 3.47.7+ohos-0.0.1-pre`（Dart 3.13.5），用 `OHOS_FLUTTER` 或 `--flutter` 指定。
- DevEco Studio 26 / HarmonyOS Command Line Tools + OpenHarmony SDK；`ohos/build-profile.json5` 当前 `compatibleSdkVersion = 5.0.5(17)`、`targetSdkVersion = 6.0.0(20)`。
- Rust 三个 target：`aarch64-unknown-linux-ohos`、`armv7-unknown-linux-ohos`、`x86_64-unknown-linux-ohos`（已在 `rust/rust-toolchain.toml` 声明）。
- Windows 需要 `ninja`；`aws-lc-sys` 必须走 Ninja + `ohos.toolchain.cmake`，否则 CMake 会误选 MSVC。

**常用命令**

```bash
# 环境检查（默认动作）
dart ./script/build/build_ohos.dart --check

# Rust + libwindcore.so + HAP（arm64 真机/发布包）
dart ./script/build/build_ohos.dart --hap

# x86_64 模拟器；Impeller 白屏时加 --no-impeller
dart ./script/build/build_ohos.dart --hap --arch x64 --no-impeller

# 复用已有 Rust 产物，只重打 HAP
dart ./script/build/build_ohos.dart --hap --no-rust

# 签名并安装（调试 profile 会自动读取设备 UDID）
dart ./script/build/sign_ohos_hap.dart \
  --hap ohos/entry/build/default/outputs/default/entry-default-unsigned.hap \
  --device 127.0.0.1:5555 --install
```

**构建行为**

- `--hap` 顺序：`cargo build --target <ohos-triple>` → `llvm-strip --strip-unneeded` → 拷贝到 `ohos/entry/libs/arm64-v8a` 或 `ohos/entry/libs/x86_64` → `flutter build hap --target-platform ohos-arm64` 或 `ohos-x64`。
- OHOS 不走 native assets：`hook/build.dart` 对 OHOS 直接返回；FRB loader 在 OHOS 使用 `DynamicLibrary.open('libwindcore.so')`。
- 构建期间会临时修改 `pubspec.yaml`：注入 `material_ui_ohos` / `cupertino_ui_ohos` / `easy_refresh_ohos` 等 git override、桌面依赖 stub、以及 jni AOT 补丁；结束后恢复并保留 `.dart_tool/ohos_pub_backup/`。若进程被强杀，从该目录手动恢复。
- `.dart_tool/ohos_jni_patch` 是 `package:jni` 的 `Int32` OHOS ABI 补丁，**不要删除**；否则 release AOT 会报 `Int32 is missing mapping for ohos_arm64`。
- 未配置签名时 hvigor 仍可能产出 `entry-default-unsigned.hap`，但命令退出码可能非 0；以产物是否存在为准，CI 也按此判断。
- HAP 内 `versionCode` / `versionName` 有两处来源，必须都与 `pubspec.yaml` 的 `version: x.y.z+build` 一致：`build_ohos.dart --hap` 先把 `ohos/AppScope/app.json5` 的这两个字段同步成 `x.y.z` / `build`，Flutter 再写 `ohos/local.properties`（`flutter.versionName` / `flutter.versionCode`）并由 flutter-hvigor-plugin 覆盖产物。直接用 DevEco / `hvigorw` 打包或插件缺失时，静态的 `app.json5` 才是真实来源，不要手写 300038 这类值。

**设备与打包注意**

- 模拟器是 x86_64，必须 `--arch x64`；arm64 HAP 安装会报 `install parse native so failed`。
- 当前 `module.json5` 同时开启 `compressNativeLibs: true` 与 `extractNativeLibs: true`，并把 target API 提到 20；`extractNativeLibs` 需要 API 20+，只开压缩不开解压会安装成功但启动失败。
- 零售机没有通用自签证书：调试 profile 绑定设备 UDID，release 需要华为开发者账号/AGC 证书与 profile；OpenHarmony 测试证书仅验证过模拟器。
- 日志：Rust 走 HiLog，`hdc shell hilog | grep windcore`；Windows 终端可能按 GBK 解码导致中文乱码，先重定向到文件或用 `chcp 65001`。Dart 未捕获异常看 `<files>/log/uncaught.log`。

**平台实现速查**

- `path_provider` / `shared_preferences` / `file_selector` 的 OHOS 实现已并入应用：Dart 在 `lib/util/ohos/`，原生方法统一在 `ohos/entry/src/main/ets/plugins/BreezeOhosPlugin.ets`，由 `installOhosPlatformPlugins()` 在启动早期注册；不要再引入独立 OHOS 插件模块。
- OHOS 不支持 `flutter_inappwebview`、`flutter_foreground_task`；手机/平板形态的 OHOS（非 PC/2in1）也不支持文件夹选择：WebView 显示外部浏览器提示页，下载只保证前台，批量导出自动改为 zip + 逐个系统“另存为”。
- 通知、音量键、打开文件/链接、设备与电池/网络信息都走 `BreezeOhosPlugin`；写跨平台代码时先判断 `isOhos`，并避免在 OHOS 调用 Android 专属插件。
- 阅读器音量键翻页需要 ArkTS 的 `inputConsumer` 监听；改这块时同时检查 `ReaderVolumeController.listen()` 的 `isOhos` 放行，否则会出现系统音量被拦截但页面不翻页。

**常见故障**

| 现象 | 处理 |
|------|------|
| `No Hmos SDK found` / 找不到 native | 本地同时设置 `HOS_SDK_HOME`（OHOS Flutter）与 `DEVECO_SDK_HOME` / `OHOS_SDK_NATIVE`（Rust）；SDK 路径放在无空格目录 |
| Rust 链接报 `multiple input filenames provided` | SDK 路径含空格（常见于 `C:\Program Files\...`），改用无空格 junction/安装目录 |
| release AOT 报 `Int32 is missing mapping for ohos_arm64` | 检查 `.dart_tool/ohos_jni_patch/lib/_internal.dart` 是否包含 `Abi.ohosArm64`；缺失时重跑 `--hap` 让脚本重建 |
| 安装报 `install parse native so failed` | HAP ABI 与设备不符：模拟器必须 `--arch x64`，真机用默认 arm64 |
| HAP 安装成功但启动卡死/闪退 | 检查 `compressNativeLibs` 是否同时配了 `extractNativeLibs`，以及 targetSdk 是否为 API 20+ |
| 模拟器白屏 | `--hap --no-impeller`（构建后会自动恢复 `buildinfo.json5`） |
| `hdc` 日志中文乱码 | 日志是 UTF-8，重定向到文件再打开，或先 `chcp 65001` |
| hvigor 报 `00305010 Syntax Error` / `Cannot read properties of undefined (reading 'filter')` | `.flutter-plugins-dependencies` 缺 `plugins.ohos`（官方 Flutter 的 pub get 会这样重写）。`ohos/hvigorconfig.ts` 已 try/catch 跳过注入，`build_ohos.dart` 构建前也会补齐该键 |
| AOT 报 `Type 'ui.Hyphens' not found` | `.dart_tool/package_config.json` 的 `flutter` / `sky_engine` 指向了官方 Flutter（IDE 在构建期间对临时 pubspec 跑了 pub get）。`build_ohos.dart` 已固定 `FLUTTER_ROOT` 并在检测到覆盖时重试一次；仍失败就关掉 IDE 的自动 pub get 再构建 |

### 5.5 调试代理

开发模式下应用会读取 `.env.proxy` 资源文件中的 `proxy=` 配置，自动探测并设置 HTTP 代理，方便调试网络请求。

---

## 6. 代码风格与约定

### 6.1 换行与编码

- 使用 `.editorconfig`：UTF-8、LF 换行、文件末尾保留空行、去除行尾空格。
- `.gitattributes` 会将文本文件规范化为 LF；Windows 批处理文件（`*.bat`、`*.cmd`）保持 CRLF。
- Git `pre-commit` 钩子会自动对暂存文件执行 `git add --renormalize`，仅包含换行符噪音的提交会被阻止。

### 6.2 Dart 规范

- `analysis_options.yaml` 继承 `package:flutter_lints/flutter.yaml`。
- `invalid_annotation_target` 错误级别设为 `ignore`，避免代码生成注解的误报。
- `build.yaml` 配置 `json_serializable` 的 `explicit_to_json: true`。

### 6.3 命名与组织

- Dart 包名 `zephyr`，导入使用 `package:zephyr/...`；禁止相对导入（`script/lint/check_relative_imports.py` 可检查）。
- 页面模块使用 barrel 文件统一 `export` 下层子模块。
- 复杂业务优先使用 `Bloc`，轻量状态使用 `Cubit`。
- 状态类一律使用 `freezed` 生成不可变数据（`equatable` 已彻底移除，`lib/` 内零引用）。

### 6.4 Rust 规范

- Rust 使用 edition 2024，`cargo fmt` 格式化。
- **工具链由 `rust/rust-toolchain.toml` 固定为 1.96.1**，并已声明各平台 target；不要改成跟随 stable，也不要在未验证的情况下升级（`rquickjs` / `windows` 等依赖对版本敏感）。
- OHOS 交叉编译所需环境变量由 `script/build/ohos_env.dart` 统一生成，不要在脚本外手写重复的 `CC_*` / `RUSTFLAGS` / `BINDGEN_EXTRA_CLANG_ARGS`。
- FRB 导出函数使用 `#[frb]`、`#[frb(sync)]`、`#[frb(init)]` 等宏标记。

---

## 7. 测试策略

- **单元/widget 测试**：`test/`（`flutter test`），覆盖下载队列、同步核心、搜索框、漫画跟随/阅读、书架、设置等；`test/test_helper.dart` 为共享 fixture。`test/widget_test.dart` 仅为占位空壳。
- **Rust 测试**：在 `rust/` 下运行 `cargo test`；涉及 `host-fronting` 等可选 feature 时，分别跑带/不带 feature 的配置。
- **集成测试**：`integration_test/`（Android RealSR / CoreML 超分端到端验证）。
- **OHOS 验证**：没有宿主机自动化覆盖 ArkTS 侧；先跑 `dart ./script/build/build_ohos.dart --check`，再构建 HAP 并用 `sign_ohos_hap.dart --install` 安装到模拟器/真机。系统能力可用 `tool/ohos/*_probe.dart` 作为 `--entry` 单独启动验证（例如 `runtime_probe`、`notification_probe`、`volume_probe`）。
- **安装器**：`windows-installer/breeze.iss` 通过 `ISCC.exe` 编译；本地验证需运行 `dart ./script/build/build_windows.dart` 后执行生成的安装器，覆盖全新安装、旧 Tauri 版本升级、运行中安装与卸载。
- 新增复杂业务时沿用 `test/` 现有风格补测试；核心逻辑修改后仍需在目标平台手动运行验证。

---

## 8. 部署与发布

### 8.1 CI/CD 工作流

- **`.github/workflows/push-build.yml`**：`push` / `pull_request` 到 `main` 且改动 `lib/**` 或 `rust/**` 时触发，并行构建 Android / Linux / Windows / macOS / iOS / HarmonyOS 产物为 artifact，**不发布 Release**。HarmonyOS job 直接 `uses: ./.github/workflows/ohos-build.yml`（复用同一份 HAP 构建逻辑），产物为未签名 `Breeze-ohos-arm64-release`。workflow 级 concurrency 只在 `pull_request` 上取消被新推送覆盖的旧构建，`main` 的推送互不取消（保证每个提交都有完整产物）。Android 构建前会安装 CMake 3.22.1，运行 `script/android/prepare_android_waifu2x_deps.py` 准备 OpenCV / libwebp 依赖，再依次运行 `script/android/build_ncnn_static_android.py` 与 `script/android/build_waifu2x_cli_android.py` 生成 `libwaifu2x_cli.so`；NCNN 模型不再随包打包，改为首次运行时下载。Windows 构建前会安装 Inno Setup 7，由 `script/build/build_windows.dart` 调用 `ISCC.exe` 生成安装包。
- **`.github/workflows/ohos-build.yml`**：HAP 构建的唯一实现，既支持手动触发（`workflow_dispatch`，可选 `arch=arm64|x64`、`build_mode=release|debug`、入口文件），也被 `push-build.yml` / `release.yml` 通过 `workflow_call` 复用（`workflow_call` 输入只能是 string，非法值由 job 内「校验输入参数」步骤拦截）。使用官方 Flutter 3.50.0 跑脚本、OHOS Flutter `3.47.7+ohos-0.0.1-pre` 构建、`ErBWs/setup-ohos` 提供 CLI 26，并在 Rust 工具链步骤同时安装 `aarch64-unknown-linux-ohos` 与 `x86_64-unknown-linux-ohos`（只装一个会导致另一 arch 失败）。未签名 HAP 存在时脚本退出码非 0 也按成功处理，产物为 `Breeze-ohos-<arch>-<mode>` artifact。
- **`.github/workflows/release.yml`**：手动触发（`workflow_dispatch`），输入版本号后构建 Android / Linux / Windows / macOS / iOS / HarmonyOS 产物，上传符号表到 Sentry，创建 GitHub Release，更新 Homebrew Cask / Flathub，并发送 Telegram 通知。HarmonyOS job 复用 `ohos-build.yml`（arm64 release），`publish` 把 HAP 改名为 `Breeze-ohos-arm64-<version>.hap` 后随 Release 发布，并在下载表格中标注「未签名」。同一版本号有 workflow 级 concurrency 兜底，避免重复触发。Android 构建前同样会准备 waifu2x CLI 依赖并编译 CLI。
- **`.github/workflows/update-plugin-list.yml`**：每天定时从 `Breeze-plugin-list` 拉取插件名，更新 `README.md` / `README.en.md` 的插件列表标记区。
- **`.github/workflows/update-tag-on-release.yml`**：Release 构建成功后触发，更新 `update-tag-version/latest-release.json` 并刷新 jsDelivr CDN tag（客户端插件/资源走该 tag 拉取）。
- **`.github/workflows/release_to_telegram.yml`**：Release `published` 时触发，向 Telegram 发送版本消息与附件。
- **`.github/workflows/signpath-smoke.yml`**：签名通道冒烟测试，与正式构建解耦。

### 8.2 发布前准备

1. 更新 `pubspec.yaml` 中的 `version`。
2. 在 `CHANGELOG.md` 顶部按格式追加新版本日志（格式：`## [vX.Y.Z]`）。
3. 提交并推送后手动触发 `release.yml`。
4. HarmonyOS 由 `release.yml` 里的 `build-ohos` job 复用 `ohos-build.yml` 自动构建并随 Release 发布（`Breeze-ohos-arm64-<version>.hap`），不需要再手动触发或附加；不要试图用 OpenHarmony 测试证书替代零售机可用的 release 签名。需要 x64 / debug / 其他入口时再单独手动跑 `ohos-build.yml`。

### 8.3 敏感文件

- `android/key.properties` 与 `android/Breeze-key.keystore` 使用 **git-crypt** 加密。
- CI 中通过 `secrets.GIT_CRYPT_KEY` 解密。
- 未解密前请勿修改这些文件，避免破坏加密状态。
- `ohos/local.properties` 由 Flutter 构建生成（含本机 SDK 路径与 versionCode），已在 `ohos/.gitignore` 中忽略；不要提交或依赖其中的路径。

### 8.4 Sentry 配置

- Release 构建通过 `--dart-define=sentry_dsn=...` 注入 DSN。
- 上传符号表需要 `SENTRY_AUTH_TOKEN`、`SENTRY_ORG`、`SENTRY_PROJECT` 环境变量。
- `pubspec.yaml` 中已配置 `sentry:` 段落。

---

## 9. 安全与合规注意事项

- **TLS 校验**：应用在初始化时调用 `setTlsVerifyEnabled(enabled: false)`，默认关闭 TLS 证书校验。这是为兼容部分自签名证书图源，但会降低网络安全性；修改前请充分评估影响。
- **代理配置**：支持 HTTP / SOCKS5 代理，开发时通过 `.env.proxy` 配置，生产环境由用户在设置中配置。
- **插件系统**：插件运行在 QuickJS 沙箱中，但可执行网络请求与文件系统操作（取决于 feature）。新增宿主 API 时应注意权限边界。
- **第三方内容**：应用不直接托管漫画内容，内容由第三方插件提供。开发与发布时需遵守所在地区法律法规。
- **崩溃监控**：Release 构建启用 Sentry，会上报异常、性能样本与部分会话回放。注意保护用户隐私。
- **未签名桌面/macOS/iOS 包**：正式分发的包未进行 Apple / Windows 付费签名，首次安装可能需要用户手动放行。
- **HarmonyOS HAP**：分发的是未签名包，用户必须用自己设备信任的证书/profile 自签；零售机不信任 OpenHarmony 测试证书，调试 profile 又绑定设备 UDID，不能把测试签名当作通用发布方案。

---

## 10. 常见修改入口

| 新增页面 / 路由 | `lib/page/`、`lib/config/router/router.dart`，然后运行 `dart ./script/codegen/code_generate.dart`（§5.1） |
| 新增数据源/插件支持 | `lib/network/http/plugin/unified_comic_plugin.dart`、`rust/src/api/qjs.rs` |
| 修改数据库表结构 / 模型 | `lib/database/schema.dart`（表/索引）、`lib/database/app_database.dart`（schema 版本与迁移）、`lib/object_box/model.dart`（JSON 模型）、`rust/src/db/sql.rs`、`rust/src/api/database.rs`；改 Dart 模型后运行 codegen（§5.1） |
| 修改全局设置 | `lib/config/global/global_setting.dart` |
| 修改图片/下载逻辑 | `lib/service/download/`、`lib/network/http/picture/` |
| 修改 Rust 侧能力 | `rust/src/api/`、`rust/src/qjs/`，然后运行 `dart ./script/codegen/code_generate.dart`（§5.1） |
| 修改国际化文案 | `lib/i18n/*.i18n.json`，然后运行 `dart ./script/codegen/code_generate.dart`（§5.1） |
| 修改 OHOS 构建 / 签名 | `script/build/build_ohos.dart`、`script/build/ohos_env.dart`、`script/build/sign_ohos_hap.dart`、`ohos/`、`docs/ohos_build.md` |
| 修改 OHOS 原生桥 / 平台实现 | `ohos/entry/src/main/ets/plugins/BreezeOhosPlugin.ets`、`lib/util/ohos/`、`lib/util/ohos/platform_plugins.dart`；用 `tool/ohos/*_probe.dart` 验证 |
| 修改 OHOS 打包配置 | `ohos/build-profile.json5`、`ohos/entry/src/main/module.json5`、`ohos/AppScope/app.json5`；`versionCode` 实际来自构建生成的 `ohos/local.properties` |
| 修改 Windows 安装器 | `windows-installer/breeze.iss`、`script/build/build_windows.dart` |
| 修改 RealSR 超分逻辑 | `lib/page/setting/real_sr/service/real_sr_super_resolution.dart`、`lib/page/setting/real_sr/real_sr_setting_page.dart`、`rust/src/api/simple.rs` |
| 修改 Android RealSR 原生依赖 / waifu2x CLI | `script/android/prepare_android_waifu2x_deps.py`、`script/android/build_ncnn_static_android.py`、`script/android/build_waifu2x_cli_android.py`、`android/app/src/main/cpp/waifu2x_cli/`、`lib/page/setting/real_sr/service/real_sr_super_resolution.dart` |
| 修改桌面端 RealSR 策略/模型选择 | `lib/page/setting/real_sr/service/desktop_ncnn_model_config.dart`、`lib/page/setting/real_sr/service/real_sr_super_resolution.dart`、`lib/page/setting/real_sr/real_sr_setting_page.dart` |
| 修改 CoreML 超分（iOS/macOS） | `packages/coreml_upscale/`、`lib/debug/coreml_upscale_debug_page.dart`、`script/models/convert_realcugan_coreml.py` |
| 导入/导出应用数据 | `lib/page/setting/data_backup/`、`rust/src/api/data_backup.rs` |
| 修改 CI/CD | `.github/workflows/`、`script/` |

---

## 11. 延伸阅读

- **README.md**：用户安装指南与免责声明。
- **CHANGELOG.md**：版本发布日志。
- **OHOS 构建与平台适配**：`docs/ohos_build.md`
- **OHOS 构建辅助说明**：`third_party/README.md`
- **Android RealSR 构建文档**：`docs/android_realsr_build.md`
- **Flutter Rust Bridge 文档**：<https://cjycode.com/flutter_rust_bridge/>
