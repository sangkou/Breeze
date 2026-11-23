import 'package:zephyr/src/rust/api/qjs.dart';

/// 插件 API 调用失败：直接复用 Rust 生成的 [QjsCallFailure] 字段，
/// `source` 来自 Rust 顶层包装的本次调用插件 id。
class QjsCallException extends QjsCallFailure implements Exception {
  const QjsCallException({
    required super.source,
    required super.message,
    this.cause,
  });

  final Object? cause;

  @override
  String toString() => message;
}
