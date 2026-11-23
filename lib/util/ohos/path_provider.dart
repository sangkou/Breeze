import 'package:flutter/services.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// OHOS [PathProviderPlatform]，直接使用应用自己的系统通道。
///
/// 不再依赖 `third_party/ohos_plugins` 里的独立 OHOS 模块。
class OhosPathProvider extends PathProviderPlatform {
  static const MethodChannel _channel = MethodChannel('zephyr/ohos_file');

  @override
  Future<String?> getTemporaryPath() => _getPath('temporary');

  @override
  Future<String?> getApplicationSupportPath() => _getPath('support');

  @override
  Future<String?> getApplicationDocumentsPath() => _getPath('documents');

  @override
  Future<String?> getApplicationCachePath() => _getPath('cache');

  @override
  Future<String?> getExternalStoragePath() => _getPath('externalStorage');

  @override
  Future<List<String>?> getExternalCachePaths() => _getPaths('externalCache');

  @override
  Future<List<String>?> getExternalStoragePaths({StorageDirectory? type}) {
    return _getPaths('externalStorageDir', directory: type?.name);
  }

  @override
  Future<String?> getDownloadsPath() => _getPath('downloads');

  @override
  Future<String?> getLibraryPath() {
    throw UnsupportedError('getLibraryPath is not supported on OHOS');
  }

  Future<String?> _getPath(String type) {
    return _channel.invokeMethod<String>('getPath', {'type': type});
  }

  Future<List<String>?> _getPaths(String type, {String? directory}) {
    return _channel.invokeListMethod<String>('getPaths', {
      'type': type,
      'directory': directory ?? '',
    });
  }
}
