import 'dart:typed_data';

import 'package:cbor/simple.dart' as cbor;
import 'package:zephyr/network/http/plugin/qjs_download_runtime.dart';
import 'package:zephyr/network/http/plugin/qjs_fetch_image_result.dart';
import 'package:zephyr/src/rust/api/qjs.dart';
import 'package:zephyr/util/async/worker_pool.dart';

typedef _QjsImageDecodeTask = ({Uint8List encoded, String source});

QjsFetchImageHttpResult _decodeQjsFetchImageResult(_QjsImageDecodeTask task) {
  return QjsFetchImageHttpResult.fromCbor(
    cbor.cbor.decode(task.encoded),
    source: task.source,
  );
}

/// 调用插件图片函数，并解码 Rust reqwest 返回的 CBOR 结果信息。
///
/// `source` 使用 Rust 侧回传的本次调用插件 id，不读取插件返回值里的 source。
Future<QjsFetchImageHttpResult> executeQjsFetchImageResult({
  required String pluginId,
  required String fnPath,
  required String argsJson,
  String? runtimeName,
  String? taskGroupKey,
}) async {
  final result = await runQjsTask<QjsCallResult>(
    pluginId: pluginId,
    fnPath: fnPath,
    argsJson: argsJson,
    runtimeName: runtimeName,
    taskGroupKey: taskGroupKey,
    call: qjsFetchImage,
  );
  final bytes = result.bytes;
  final source = result.source;
  // 大图 CBOR 解码会阻塞 UI isolate（Sentry ANR: _readBytes），放到后台 isolate。
  return runInIsolate(_decodeQjsFetchImageResult, (
    encoded: bytes,
    source: source,
  ));
}
