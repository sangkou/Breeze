import 'package:flutter/services.dart';
import 'package:open_file/open_file.dart';

import 'package:zephyr/util/ohos/platform.dart';

/// App 级 OHOS 系统通道（实现在 ohos/entry/.../BreezeOhosPlugin.ets）。
const MethodChannel _channel = MethodChannel('zephyr/ohos_file');

/// 打开文件：OHOS 走系统 startAbility，其他平台仍用 open_file 插件。
Future<OpenResult> openFileWithSystem(String path, {String? type}) async {
  if (!isOhos) return OpenFile.open(path, type: type);
  try {
    await _channel.invokeMethod<void>('openFile', {'path': path, 'mime': type});
    return OpenResult(type: ResultType.done);
  } catch (error) {
    return OpenResult(type: ResultType.error, message: '$error');
  }
}

/// 保存图片到系统相册（OHOS 会弹系统保存确认框）。
Future<void> saveImageToOhosGallery(String path) async {
  if (!isOhos) {
    throw UnsupportedError('saveImageToOhosGallery is OHOS-only');
  }
  await _channel.invokeMethod<void>('saveImage', {'path': path});
}

/// 系统文件选择器（OHOS）：选中的文件会复制到应用缓存，返回可直接读取的路径。
Future<String?> pickOhosFile({List<String> suffixes = const <String>[]}) async {
  if (!isOhos) {
    throw UnsupportedError('pickOhosFile is OHOS-only');
  }
  return _channel.invokeMethod<String>('pickFile', {'suffixes': suffixes});
}

/// 系统另存为（OHOS）：把本地文件复制到用户选择的位置。
Future<bool> saveOhosFileToPicker(String path, {String? suggestedName}) async {
  if (!isOhos) {
    throw UnsupportedError('saveOhosFileToPicker is OHOS-only');
  }
  return await _channel.invokeMethod<bool>('saveFile', {
        'path': path,
        'suggestedName': suggestedName ?? '',
      }) ??
      false;
}

/// 请求 OHOS 通知权限，返回最终是否开启。
Future<bool> requestOhosNotificationPermission() async {
  if (!isOhos) {
    throw UnsupportedError('requestOhosNotificationPermission is OHOS-only');
  }
  return await _channel.invokeMethod<bool>('requestNotificationPermission') ??
      false;
}

/// OHOS 包信息（不依赖 package_info_plus 插件）。
class OhosPackageInfo {
  const OhosPackageInfo({required this.version, required this.buildNumber});

  final String version;
  final String buildNumber;
}

/// OHOS 设备信息（不依赖 device_info_plus 插件）。
class OhosDeviceInfo {
  const OhosDeviceInfo({
    required this.brand,
    required this.manufacturer,
    required this.model,
    required this.osVersion,
    required this.sdkApiVersion,
    required this.abis,
  });

  final String brand;
  final String manufacturer;
  final String model;
  final String osVersion;
  final int sdkApiVersion;
  final List<String> abis;
}

/// OHOS 电池状态。
class OhosBatteryInfo {
  const OhosBatteryInfo({required this.level, required this.state});

  final int level;

  /// `charging` / `full` / `discharging` / `unknown`。
  final String state;
}

/// OHOS 应用版本号与构建号。
Future<OhosPackageInfo?> getOhosPackageInfo() async {
  if (!isOhos) {
    throw UnsupportedError('getOhosPackageInfo is OHOS-only');
  }
  final info = await _channel.invokeMapMethod<String, dynamic>(
    'getPackageInfo',
  );
  if (info == null) return null;
  return OhosPackageInfo(
    version: info['version'] as String? ?? '',
    buildNumber: info['buildNumber'] as String? ?? '',
  );
}

/// OHOS 应用版本号（不依赖 package_info_plus 插件）。
Future<String?> getOhosAppVersion() async {
  final info = await getOhosPackageInfo();
  return info?.version;
}

/// OHOS 设备基础信息。
Future<OhosDeviceInfo?> getOhosDeviceInfo() async {
  if (!isOhos) {
    throw UnsupportedError('getOhosDeviceInfo is OHOS-only');
  }
  final raw = await _channel.invokeMapMethod<String, dynamic>('getDeviceInfo');
  if (raw == null) return null;
  return OhosDeviceInfo(
    brand: raw['brand'] as String? ?? '',
    manufacturer: raw['manufacturer'] as String? ?? '',
    model: raw['model'] as String? ?? '',
    osVersion: raw['osVersion'] as String? ?? '',
    sdkApiVersion: (raw['sdkApiVersion'] as num?)?.toInt() ?? 0,
    abis: (raw['abis'] as List?)?.cast<String>() ?? const <String>[],
  );
}

/// OHOS 当前网络类型列表：wifi / mobile / ethernet / bluetooth / vpn / none / other。
Future<List<String>> getOhosConnectivity() async {
  if (!isOhos) {
    throw UnsupportedError('getOhosConnectivity is OHOS-only');
  }
  return await _channel.invokeListMethod<String>('getConnectivity') ??
      const <String>['none'];
}

/// OHOS 当前电池电量与充电状态。
Future<OhosBatteryInfo?> getOhosBatteryInfo() async {
  if (!isOhos) {
    throw UnsupportedError('getOhosBatteryInfo is OHOS-only');
  }
  final raw = await _channel.invokeMapMethod<String, dynamic>('getBatteryInfo');
  if (raw == null) return null;
  return OhosBatteryInfo(
    level: (raw['level'] as num?)?.toInt() ?? 100,
    state: raw['state'] as String? ?? 'unknown',
  );
}

/// 用系统能力打开链接（OHOS 不依赖 url_launcher）。
Future<bool> openOhosUrl(String uri) async {
  if (!isOhos) {
    throw UnsupportedError('openOhosUrl is OHOS-only');
  }
  return await _channel.invokeMethod<bool>('openUrl', {'uri': uri}) ?? false;
}
