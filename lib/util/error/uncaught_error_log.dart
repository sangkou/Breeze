import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:logger/logger.dart';
import 'package:path/path.dart' as p;
import 'package:zephyr/util/error/error_filter.dart';

/// 只记录未捕获异常的日志器。
///
/// 普通业务日志仍只输出到控制台/远端日志，不落盘；避免请求参数、账号密码
/// 等敏感内容被写入设备文件。该日志器只接收 Flutter/平台未捕获异常。
///
/// 文件写入放在常驻后台 isolate，UI isolate 只负责格式化并投递消息。
class UncaughtErrorFileLogger {
  UncaughtErrorFileLogger({
    required this.file,
    this.maxBytes = 2 * 1024 * 1024,
  }) {
    _writer = _IsolateLogWriter(file: file, maxBytes: maxBytes);
    _logger = Logger(
      filter: ProductionFilter(),
      printer: _UncaughtLogPrinter(),
      output: _QueuedLogOutput(_writer),
    );
  }

  final File file;
  final int maxBytes;
  late final _IsolateLogWriter _writer;
  late final Logger _logger;

  void log(
    Object error,
    StackTrace stackTrace, {
    String source = 'Uncaught error',
  }) {
    try {
      _logger.e(source, error: error, stackTrace: stackTrace);
    } catch (_) {
      // 日志失败不能反过来制造新的未捕获异常。
    }
  }

  /// 等待队列中的日志落盘，主要用于测试和正常退出路径。
  Future<void> flush() => _writer.flush();

  Future<void> close() => _writer.close();
}

class _QueuedLogOutput extends LogOutput {
  _QueuedLogOutput(this.writer);

  final _IsolateLogWriter writer;

  @override
  void output(OutputEvent event) {
    writer.write('${event.lines.join('\n')}\n');
  }
}

/// 文件日志用纯文本，避免控制台 ANSI/emoji/边框影响 grep。
class _UncaughtLogPrinter extends LogPrinter {
  @override
  List<String> log(LogEvent event) {
    final buffer = StringBuffer()
      ..writeln(
        '${event.time.toIso8601String()} '
        '${event.level.name.toUpperCase()} '
        '${sanitizeErrorText(event.message, maxLength: 4000)}',
      );
    if (event.error != null) {
      buffer.writeln(
        'Error: ${sanitizeErrorText(event.error!, maxLength: 4000)}',
      );
    }
    if (event.stackTrace != null) {
      buffer.write(sanitizeErrorText(event.stackTrace!, maxLength: 8000));
      buffer.writeln();
    }
    return [buffer.toString().trimRight()];
  }
}

class _IsolateLogWriter {
  _IsolateLogWriter({required this.file, required this.maxBytes}) {
    _start();
  }

  final File file;
  final int maxBytes;
  final List<String> _pending = <String>[];
  final Completer<SendPort?> _ready = Completer<SendPort?>();
  SendPort? _sendPort;
  bool _closed = false;

  Future<void> _start() async {
    final handshake = ReceivePort();
    try {
      await Isolate.spawn<Map<String, Object?>>(
        _logWriterMain,
        <String, Object?>{
          'path': file.path,
          'maxBytes': maxBytes,
          'ready': handshake.sendPort,
        },
        debugName: 'breeze-uncaught-log',
        onExit: handshake.sendPort,
      );
      final port = await handshake.first.timeout(const Duration(seconds: 10));
      handshake.close();
      if (port is! SendPort || _closed) {
        _ready.complete(null);
        return;
      }
      _ready.complete(port);
      _sendPort = port;
      for (final line in _pending) {
        port.send(line);
      }
      _pending.clear();
    } catch (_) {
      handshake.close();
      if (!_ready.isCompleted) _ready.complete(null);
    }
  }

  void write(String line) {
    if (_closed) return;
    final port = _sendPort;
    if (port != null) {
      port.send(line);
      return;
    }
    // isolate 尚未握手完成：先短暂排队，避免启动早期异常丢失。
    if (_pending.length >= 64) {
      _pending.removeAt(0);
    }
    _pending.add(line);
  }

  Future<void> flush() async {
    final port = await _ready.future;
    if (port == null || _closed) return;
    final reply = ReceivePort();
    try {
      port.send(<String, Object?>{'type': 'flush', 'reply': reply.sendPort});
      await reply.first.timeout(const Duration(seconds: 2));
    } finally {
      reply.close();
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final port = await _ready.future;
    if (port == null) return;
    final reply = ReceivePort();
    try {
      port.send(<String, Object?>{'type': 'close', 'reply': reply.sendPort});
      await reply.first.timeout(const Duration(seconds: 2));
    } finally {
      reply.close();
    }
  }
}

Future<void> _logWriterMain(Map<String, Object?> init) async {
  final receive = ReceivePort();
  (init['ready'] as SendPort).send(receive.sendPort);
  final writer = _LogFileWriter(
    path: init['path'] as String,
    maxBytes: init['maxBytes'] as int,
  );

  await for (final message in receive) {
    try {
      if (message is String) {
        await writer.write(message);
      } else if (message is Map) {
        switch (message['type']) {
          case 'flush':
            await writer.flush();
            (message['reply'] as SendPort?)?.send(null);
          case 'close':
            await writer.close();
            (message['reply'] as SendPort?)?.send(null);
            receive.close();
            return;
        }
      }
    } catch (_) {
      // 写失败只丢弃这一条，保持 isolate 继续处理后续日志。
    }
  }
}

class _LogFileWriter {
  _LogFileWriter({required this.path, required this.maxBytes});

  final String path;
  final int maxBytes;
  RandomAccessFile? _file;

  Future<void> write(String text) async {
    await _ensureOpen();
    final file = _file;
    if (file == null) return;

    if (await file.length() >= maxBytes) {
      await _rotate();
      await _ensureOpen();
    }
    await _file!.writeString(text);
    await _file!.flush();
  }

  Future<void> _ensureOpen() async {
    if (_file != null) return;
    final target = File(path);
    await target.parent.create(recursive: true);
    _file = await target.open(mode: FileMode.append);
  }

  Future<void> _rotate() async {
    await _file?.close();
    _file = null;
    final target = File(path);
    final backup = File('$path.1');
    if (await backup.exists()) {
      await backup.delete();
    }
    if (await target.exists()) {
      await target.rename(backup.path);
    }
  }

  Future<void> flush() async {
    await _file?.flush();
  }

  Future<void> close() async {
    await _file?.close();
    _file = null;
  }
}

UncaughtErrorFileLogger? uncaughtErrorFileLogger;

void logUncaughtError(
  Object error,
  StackTrace stackTrace, {
  String source = 'Uncaught error',
}) {
  uncaughtErrorFileLogger?.log(error, stackTrace, source: source);
}

/// 创建未捕获异常日志文件；调用方负责在 OHOS 启动早期调用。
Future<UncaughtErrorFileLogger?> initUncaughtErrorFileLogger(
  String logDirectory,
) async {
  try {
    final file = File(p.join(logDirectory, 'uncaught.log'));
    return uncaughtErrorFileLogger = UncaughtErrorFileLogger(file: file);
  } catch (_) {
    return null;
  }
}
