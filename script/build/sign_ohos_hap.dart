#!/usr/bin/env dart

// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'ohos_env.dart';

const String _reset = '\x1B[0m';
const String _red = '\x1B[31m';
const String _green = '\x1B[32m';
const String _cyan = '\x1B[36m';

class _Options {
  String hap = '';
  String? out;
  String bundle = 'com.zephyr.breeze.ohos';
  String? udid;
  String? device;
  bool install = false;
  bool release = false;
  String? keystore;
  String keystorePassword = '123456';
  String keyAlias = 'openharmony application release';
  String? appCert;
  String? profileP7b;
  bool help = false;

  static _Options parse(List<String> args) {
    final options = _Options();
    for (var i = 0; i < args.length; i++) {
      String value(String name) {
        if (i + 1 >= args.length) throw ArgumentError('$name 需要一个值');
        return args[++i];
      }

      final arg = args[i];
      switch (arg) {
        case '--hap':
          options.hap = value(arg);
        case '--out':
          options.out = value(arg);
        case '--bundle':
          options.bundle = value(arg);
        case '--udid':
          options.udid = value(arg);
        case '--device':
          options.device = value(arg);
        case '--keystore':
          options.keystore = value(arg);
        case '--keystore-password':
          options.keystorePassword = value(arg);
        case '--key-alias':
          options.keyAlias = value(arg);
        case '--app-cert':
          options.appCert = value(arg);
        case '--profile-p7b':
          options.profileP7b = value(arg);
        case '--install':
          options.install = true;
        case '--release':
          options.release = true;
        case '--help' || '-h':
          options.help = true;
        default:
          throw ArgumentError('未知参数: $arg');
      }
    }
    return options;
  }
}

Future<void> main(List<String> args) async {
  final _Options options;
  try {
    options = _Options.parse(args);
  } on ArgumentError catch (error) {
    _print(error.message.toString(), _red);
    _usage();
    exitCode = 64;
    return;
  }
  if (options.help) {
    _usage();
    return;
  }
  if (options.hap.isEmpty) {
    _print('缺少 --hap', _red);
    _usage();
    exitCode = 64;
    return;
  }

  final hap = File(p.normalize(p.absolute(options.hap)));
  if (!hap.existsSync()) {
    _print('HAP 不存在: ${hap.path}', _red);
    exitCode = 66;
    return;
  }

  try {
    await _sign(options, hap);
  } catch (error) {
    _print('签名失败: $error', _red);
    exitCode = 1;
  }
}

Future<void> _sign(_Options options, File hap) async {
  final nativeDir = findOhosNativeDir();
  final sdkRoot = ohosSdkRoot(nativeDir);
  final libDir = p.join(sdkRoot, 'toolchains', 'lib');
  final toolchainDir = p.join(sdkRoot, 'toolchains');
  final hdc = p.join(toolchainDir, Platform.isWindows ? 'hdc.exe' : 'hdc');
  final java = _javaPath();
  final keytool = _keytoolPath();
  final signTool = p.join(libDir, 'hap-sign-tool.jar');
  final keystore = p.normalize(
    p.absolute(options.keystore ?? p.join(libDir, 'OpenHarmony.p12')),
  );

  final profileAlias = options.release
      ? 'openharmony application profile release'
      : 'openharmony application profile debug';
  final profileCert = p.join(
    libDir,
    options.release
        ? 'OpenHarmonyProfileRelease.pem'
        : 'OpenHarmonyProfileDebug.pem',
  );
  final templatePath = p.join(
    libDir,
    options.release
        ? 'UnsgnedReleasedProfileTemplate.json'
        : 'UnsgnedDebugProfileTemplate.json',
  );

  final workDir = Directory(
    p.join(Directory.current.path, '.dart_tool', 'ohos_sign'),
  );
  await workDir.create(recursive: true);

  var udid = options.udid;
  if (udid == null && !options.release) {
    final deviceArgs = options.device == null
        ? <String>[]
        : <String>['-t', options.device!];
    final result = await Process.run(hdc, <String>[
      ...deviceArgs,
      'shell',
      'bm',
      'get',
      '--udid',
    ]);
    final match = RegExp(r'[0-9A-Fa-f]{64}').firstMatch('${result.stdout}');
    if (match == null) {
      throw StateError('无法获取设备 UDID，请用 --udid 指定（hdc shell bm get --udid）');
    }
    udid = match.group(0);
  }

  // 1) 应用证书链：默认从 profile 模板里取 CA 签发的应用证书，
  //    再从 keystore 导出 CA/根证书拼成链。
  final String appChainPath;
  if (options.appCert != null) {
    appChainPath = p.normalize(p.absolute(options.appCert!));
  } else {
    final template = jsonDecode(
      await File(templatePath).readAsString(),
    ) as Map<String, dynamic>;
    final leaf =
        (template['bundle-info'] as Map)['development-certificate'] as String;
    final leafFile = File(p.join(workDir.path, 'app_leaf.pem'));
    await leafFile.writeAsString(leaf.endsWith('\n') ? leaf : '$leaf\n');
    final caFile = File(p.join(workDir.path, 'app_ca.pem'));
    final rootFile = File(p.join(workDir.path, 'app_root.pem'));
    await _exportCert(
      keytool,
      keystore,
      options.keystorePassword,
      'openharmony application ca',
      caFile.path,
    );
    await _exportCert(
      keytool,
      keystore,
      options.keystorePassword,
      'openharmony application root ca',
      rootFile.path,
    );
    final chain = File(p.join(workDir.path, 'app_chain.pem'));
    await chain.writeAsString(
      '${await leafFile.readAsString()}'
      '${await caFile.readAsString()}'
      '${await rootFile.readAsString()}',
    );
    appChainPath = chain.path;
  }

  // 2) profile：已有 p7b 直接用；否则按模板生成并用 profile 证书签名。
  late final String profilePath;
  if (options.profileP7b != null) {
    profilePath = p.normalize(p.absolute(options.profileP7b!));
  } else {
    final template = jsonDecode(
      await File(templatePath).readAsString(),
    ) as Map<String, dynamic>;
    (template['bundle-info'] as Map)['bundle-name'] = options.bundle;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    template['validity'] = <String, int>{
      'not-before': now - 86400,
      'not-after': now + 365 * 86400,
    };
    if (!options.release) {
      (template['debug-info'] as Map)['device-ids'] = <String>[udid!];
      (template['debug-info'] as Map)['device-id-type'] = 'udid';
    }
    final profileJson = File(p.join(workDir.path, 'profile.json'));
    await profileJson.writeAsString(
      const JsonEncoder.withIndent('  ').convert(template),
    );

    final profileP7b = File(p.join(workDir.path, 'profile.p7b'));
    await _run(java, <String>[
      '-jar',
      signTool,
      'sign-profile',
      '-mode',
      'localSign',
      '-keyAlias',
      profileAlias,
      '-keyPwd',
      options.keystorePassword,
      '-profileCertFile',
      profileCert,
      '-inFile',
      profileJson.path,
      '-signAlg',
      'SHA256withECDSA',
      '-keystoreFile',
      keystore,
      '-keystorePwd',
      options.keystorePassword,
      '-outFile',
      profileP7b.path,
    ]);
    profilePath = profileP7b.path;
  }

  // 3) 签 HAP。
  final out = File(
    p.normalize(
      options.out != null
          ? p.absolute(options.out!)
          : p.join(
              hap.parent.path,
              '${p.basenameWithoutExtension(hap.path)}-signed.hap',
            ),
    ),
  );
  await out.parent.create(recursive: true);
  await _run(java, <String>[
    '-jar',
    signTool,
    'sign-app',
    '-mode',
    'localSign',
    '-keyAlias',
    options.keyAlias,
    '-keyPwd',
    options.keystorePassword,
    '-appCertFile',
    appChainPath,
    '-profileFile',
    profilePath,
    '-inFile',
    hap.path,
    '-signAlg',
    'SHA256withECDSA',
    '-keystoreFile',
    keystore,
    '-keystorePwd',
    options.keystorePassword,
    '-outFile',
    out.path,
  ]);

  _print('已签名: ${out.path}', _green);
  if (options.install) {
    final deviceArgs = options.device == null
        ? <String>[]
        : <String>['-t', options.device!];
    final result = await Process.run(hdc, <String>[
      ...deviceArgs,
      'install',
      '-r',
      p.basename(out.path),
    ], workingDirectory: out.parent.path);
    stdout.write(result.stdout);
    stderr.write(result.stderr);
    if (result.exitCode != 0) {
      throw StateError('hdc install 失败（exit ${result.exitCode}）');
    }
    _print('安装完成', _green);
  }
}

Future<void> _exportCert(
  String keytool,
  String keystore,
  String password,
  String alias,
  String out,
) async {
  await _run(keytool, <String>[
    '-exportcert',
    '-rfc',
    '-alias',
    alias,
    '-keystore',
    keystore,
    '-storetype',
    'PKCS12',
    '-storepass',
    password,
    '-file',
    out,
  ]);
}

Future<void> _run(String executable, List<String> args) async {
  final masked = <String>[];
  var maskNext = false;
  for (final arg in args) {
    if (maskNext) {
      masked.add('******');
      maskNext = false;
    } else {
      masked.add(arg);
    }
    if (arg == '-keyPwd' || arg == '-keystorePwd' || arg == '-storepass') {
      maskNext = true;
    }
  }
  _print('> $executable ${masked.join(' ')}', _cyan);
  final result = await Process.run(executable, args);
  if (result.exitCode != 0) {
    stdout.write(result.stdout);
    stderr.write(result.stderr);
    throw StateError('命令失败（exit ${result.exitCode}）');
  }
}

String _javaPath() {
  final home = Platform.environment['JAVA_HOME'];
  if (home != null && home.isNotEmpty) {
    final java = p.join(home, 'bin', Platform.isWindows ? 'java.exe' : 'java');
    if (File(java).existsSync()) return java;
  }
  if (Platform.isWindows) {
    final jbr = r'C:\Program Files\Huawei\DevEco Studio\jbr\bin\java.exe';
    if (File(jbr).existsSync()) return jbr;
  }
  return 'java';
}

String _keytoolPath() {
  final home = Platform.environment['JAVA_HOME'];
  if (home != null && home.isNotEmpty) {
    final keytool = p.join(
      home,
      'bin',
      Platform.isWindows ? 'keytool.exe' : 'keytool',
    );
    if (File(keytool).existsSync()) return keytool;
  }
  if (Platform.isWindows) {
    final jbr = r'C:\Program Files\Huawei\DevEco Studio\jbr\bin\keytool.exe';
    if (File(jbr).existsSync()) return jbr;
  }
  return 'keytool';
}

void _print(String message, String color) => print('$color$message$_reset');

void _usage() {
  print('''
用法: dart ./script/build/sign_ohos_hap.dart --hap <unsigned.hap> [选项]

默认使用 SDK 自带的 OpenHarmony 测试证书 + 调试 profile（绑定设备 UDID，
仅适用于模拟器/OpenHarmony 设备；HarmonyOS 零售机需要华为签发的证书）。

选项:
  --out <path>            输出 HAP，默认 <输入>-signed.hap
  --bundle <name>         bundleName，默认 com.zephyr.breeze.ohos
  --udid <udid>           设备 UDID，默认自动 hdc shell bm get --udid
  --device <id>           hdc 目标，如 127.0.0.1:5555
  --release               使用 release profile 模板
  --install               签名后 hdc install -r
  --keystore <p12>        自定义 keystore
  --keystore-password <p> keystore/key 密码，默认 123456
  --key-alias <alias>     应用签名 key 别名
  --app-cert <pem>        自定义应用证书链（跳过模板证书）
  --profile-p7b <p7b>     已有签名 profile（跳过 profile 签名）
  -h, --help              显示帮助
''');
}
