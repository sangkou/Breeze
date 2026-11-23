import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/services.dart';

/// OHOS [FileSelectorPlatform]，直接使用应用自己的系统通道。
///
/// 选中的文件由 ArkTS 侧复制到应用缓存，返回普通文件系统路径。
class OhosFileSelector extends FileSelectorPlatform {
  static const MethodChannel _channel = MethodChannel('zephyr/ohos_file');

  @override
  Future<XFile?> openFile({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async {
    final path = await _channel.invokeMethod<String>('pickFile', {
      'suffixes': _suffixes(acceptedTypeGroups),
    });
    return path == null ? null : XFile(path);
  }

  @override
  Future<List<XFile>> openFiles({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async {
    final paths =
        await _channel.invokeListMethod<String>('pickFiles', {
          'suffixes': _suffixes(acceptedTypeGroups),
        }) ??
        const <String>[];
    return paths.map(XFile.new).toList();
  }

  @override
  Future<String?> getDirectoryPath({
    String? initialDirectory,
    String? confirmButtonText,
  }) async {
    // OHOS(非 PC/2in1)不支持文件夹选择；上层已改为单文件/压缩包保存。
    return null;
  }

  @override
  Future<List<String>> getDirectoryPaths({
    String? initialDirectory,
    String? confirmButtonText,
  }) async {
    return const <String>[];
  }

  @override
  Future<String?> getSavePath({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? suggestedName,
    String? confirmButtonText,
  }) {
    return _channel.invokeMethod<String>('pickSavePath', {
      'suggestedName': suggestedName ?? '',
    });
  }

  List<String> _suffixes(List<XTypeGroup>? groups) {
    final result = <String>[];
    for (final group in groups ?? const <XTypeGroup>[]) {
      for (final extension in group.extensions ?? const <String>[]) {
        final value = extension.trim();
        if (value.isNotEmpty) {
          result.add(value);
        }
      }
    }
    return result;
  }
}
