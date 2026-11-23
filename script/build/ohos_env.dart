import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:path/path.dart' as p;

/// OpenHarmony 目标三元组（Rust 侧）。
const String ohosArm64Triple = 'aarch64-unknown-linux-ohos';
const String ohosArmTriple = 'armv7-unknown-linux-ohos';
const String ohosX64Triple = 'x86_64-unknown-linux-ohos';

/// Rust target triple -> clang target triple。
///
/// clang 不认识 Rust 的 `-unknown-linux-ohos` 厂商段，链接/编译 C 代码时
/// 使用 clang 自己的三元组；bindgen 则可以直接使用 Rust 三元组。
String ohosTargetTriple(Architecture architecture) {
  return switch (architecture) {
    Architecture.arm64 => ohosArm64Triple,
    Architecture.arm => ohosArmTriple,
    Architecture.x64 => ohosX64Triple,
    _ => throw UnsupportedError(
      'Unsupported OpenHarmony architecture: $architecture',
    ),
  };
}

String ohosClangTriple(Architecture architecture) {
  return switch (architecture) {
    Architecture.arm64 => 'aarch64-linux-ohos',
    Architecture.arm => 'armv7-linux-ohos',
    Architecture.x64 => 'x86_64-linux-ohos',
    _ => throw UnsupportedError(
      'Unsupported OpenHarmony architecture: $architecture',
    ),
  };
}

/// 查找 OpenHarmony SDK 的 `native` 目录。
///
/// 该目录应包含 `llvm/`、`sysroot/` 和 `build/cmake/ohos.toolchain.cmake`。
/// 支持以下环境变量：
/// - `OHOS_SDK_NATIVE`：直接指向 `native` 目录；
/// - `OHOS_NDK_HOME` / `DEVECO_SDK_HOME` / `OHOS_SDK_HOME`：SDK 根目录，
///   其下可能是 `native/` 或 `default/openharmony/native/`。
String findOhosNativeDir() {
  final environment = Platform.environment;
  final localAppData = environment['LOCALAPPDATA'];
  final candidates = <String>[
    ?environment['OHOS_SDK_NATIVE'],
    ?environment['OHOS_NDK_HOME'],
    ?environment['DEVECO_SDK_HOME'],
    ?environment['OHOS_SDK_HOME'],
    if (localAppData != null) p.join(localAppData, 'Huawei', 'Sdk'),
    if (localAppData != null) p.join(localAppData, 'OpenHarmony', 'Sdk'),
    if (Platform.isWindows) r'C:\Program Files\Huawei\DevEco Studio\sdk',
  ];

  for (final candidate in candidates) {
    final nativeDir = _probeOhosNativeDir(candidate);
    if (nativeDir != null) return nativeDir;
  }

  throw StateError(
    'Cannot find the OpenHarmony SDK. Set OHOS_SDK_NATIVE to the SDK '
    '`native` directory, or DEVECO_SDK_HOME to the DevEco SDK root. '
    'Download: '
    'https://repo.huaweicloud.com/openharmony/os/5.0.0-Release/'
    'ohos-sdk-windows_linux-public.tar.gz',
  );
}

String? _probeOhosNativeDir(String root) {
  final candidates = <String>[
    root,
    p.join(root, 'native'),
    p.join(root, 'default', 'openharmony', 'native'),
    p.join(root, 'sdk', 'default', 'openharmony', 'native'),
  ];
  for (final candidate in candidates) {
    if (File(p.join(candidate, 'build', 'cmake', 'ohos.toolchain.cmake'))
        .existsSync()) {
      return candidate;
    }
  }
  return null;
}

/// SDK 根目录（`native` 的父目录），供 aws-lc-sys 的 `OHOS_NDK_HOME` 使用。
String ohosSdkRoot(String nativeDir) => p.dirname(nativeDir);

String ohosLlvmBase(String nativeDir) => p.join(nativeDir, 'llvm');

String? ohosClangVersion(String nativeDir) {
  final clangDir = Directory(p.join(ohosLlvmBase(nativeDir), 'lib', 'clang'));
  if (!clangDir.existsSync()) return null;
  for (final entity in clangDir.listSync()) {
    if (entity is Directory &&
        RegExp(r'^\d+').hasMatch(p.basename(entity.path))) {
      return p.basename(entity.path);
    }
  }
  return null;
}

/// 生成构建 OpenHarmony 目标所需的 cargo / bindgen 环境变量。
///
/// 返回值可以直接合并进 `Platform.environment` 后传给 `cargo build`。
Map<String, String> ohosEnvironmentVariables({
  required Architecture architecture,
  required String nativeDir,
}) {
  final llvmBase = ohosLlvmBase(nativeDir);
  final binDir = p.join(llvmBase, 'bin');
  final sysroot = p.join(nativeDir, 'sysroot');
  final targetTriple = ohosTargetTriple(architecture);
  final clangTriple = ohosClangTriple(architecture);
  final envTriple = targetTriple.replaceAll('-', '_');
  final clang = p.join(binDir, 'clang${_exeSuffix()}');
  final clangPp = p.join(binDir, 'clang++${_exeSuffix()}');
  final ar = p.join(binDir, 'llvm-ar${_exeSuffix()}');
  final clangVersion = ohosClangVersion(nativeDir);

  final bindgenArgs = <String>[
    '--target=$targetTriple',
    if (clangVersion != null)
      '-resource-dir ${_quoteClangArg(p.join(llvmBase, 'lib', 'clang', clangVersion))}',
    '--sysroot=${_quoteClangArg(sysroot)}',
    '-isystem ${_quoteClangArg(p.join(sysroot, 'usr', 'include'))}',
    if (Directory(p.join(sysroot, 'usr', 'include', targetTriple)).existsSync())
      '-isystem ${_quoteClangArg(p.join(sysroot, 'usr', 'include', targetTriple))}',
    if (Directory(p.join(sysroot, 'usr', 'include', clangTriple)).existsSync())
      '-isystem ${_quoteClangArg(p.join(sysroot, 'usr', 'include', clangTriple))}',
  ].join(' ');

  final cc =
      '${_quoteClangArg(clang)} --target=$clangTriple --sysroot=${_quoteClangArg(sysroot)}';
  final cxx =
      '${_quoteClangArg(clangPp)} --target=$clangTriple --sysroot=${_quoteClangArg(sysroot)}';

  final existingRustFlags = Platform.environment['RUSTFLAGS']?.trim();
  final existingLibclangPath = Platform.environment['LIBCLANG_PATH']?.trim();
  final existingGenerator = Platform.environment['CMAKE_GENERATOR']?.trim();
  final rustFlags = <String>[
    if (existingRustFlags != null && existingRustFlags.isNotEmpty)
      existingRustFlags,
    '-C link-arg=--target=$clangTriple',
    '-C link-arg=--sysroot=$sysroot',
  ].join(' ');

  return <String, String>{
    // aws-lc-sys 通过这两个变量查找 ohos.toolchain.cmake。
    'OHOS_NDK_HOME': ohosSdkRoot(nativeDir),
    'OHOS_SDK_NATIVE': nativeDir,
    // flutter_rust_bridge 的 OHOS 文档要求的变量，指向 native 目录。
    'OHOS_SDK_HOME': nativeDir,
    // Windows 上 CMake 默认选 Visual Studio 生成器，会拿 cl.exe 编译
    // OHOS 目标而失败；aws-lc-sys 必须走 Ninja + ohos.toolchain.cmake。
    if (existingGenerator == null || existingGenerator.isEmpty)
      'CMAKE_GENERATOR': 'Ninja',
    'CLANG_PATH': clang,
    if (existingLibclangPath == null || existingLibclangPath.isEmpty)
      'LIBCLANG_PATH': binDir,
    'BINDGEN_EXTRA_CLANG_ARGS': bindgenArgs,
    'CC_$envTriple': cc,
    'CXX_$envTriple': cxx,
    'AR_$envTriple': ar,
    // OHOS libc 没有 pthread_mutex_consistent/setrobust；LMDB 默认启用
    // robust mutex 会在加载 libwindcore.so 时因找不到符号而失败。
    // 我们只做只读的 ObjectBox 遗留导入，关闭 robust 即可。
    'CFLAGS_$envTriple': '-DMDB_USE_ROBUST=0',
    'CARGO_TARGET_${envTriple.toUpperCase()}_LINKER': clang,
    'RUSTFLAGS': rustFlags,
    'PATH': '$binDir${_pathSep()}${Platform.environment['PATH'] ?? ''}',
  };
}

String readRustToolchainChannel(String crateDirectory) {
  final file = File(p.join(crateDirectory, 'rust-toolchain.toml'));
  if (file.existsSync()) {
    final match = RegExp(r'channel\s*=\s*"([^"]+)"')
        .firstMatch(file.readAsStringSync());
    if (match != null) return match.group(1)!;
  }
  return '1.96.1';
}

/// bindgen 用 shlex 解析 `BINDGEN_EXTRA_CLANG_ARGS`，带空格的路径需要引号。
String _quoteClangArg(String path) {
  final normalized = path.replaceAll('\\', '/');
  return normalized.contains(' ') ? '"$normalized"' : normalized;
}

String _exeSuffix() => Platform.isWindows ? '.exe' : '';

String _pathSep() => Platform.isWindows ? ';' : ':';
