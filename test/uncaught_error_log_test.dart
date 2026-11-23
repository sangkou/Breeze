import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zephyr/util/error/uncaught_error_log.dart';

void main() {
  test('writes uncaught errors with stack trace', () async {
    final dir = Directory.systemTemp.createTempSync('breeze_uncaught_log_');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final file = File(p.join(dir.path, 'uncaught.log'));
    final logger = UncaughtErrorFileLogger(file: file);

    logger.log(StateError('boom'), StackTrace.current, source: 'Test source');
    await logger.flush();

    final text = file.readAsStringSync();
    expect(text, contains('Test source'));
    expect(text, contains('boom'));
    expect(text, contains('uncaught_error_log_test.dart'));
    await logger.close();
  });

  test('rotates the log before it grows without bound', () async {
    final dir = Directory.systemTemp.createTempSync('breeze_uncaught_log_');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final file = File(p.join(dir.path, 'uncaught.log'));
    final logger = UncaughtErrorFileLogger(file: file, maxBytes: 1);

    logger.log(StateError('first'), StackTrace.current);
    await logger.flush();
    logger.log(StateError('second'), StackTrace.current);
    await logger.flush();

    expect(File('${file.path}.1').existsSync(), isTrue);
    expect(file.readAsStringSync(), contains('second'));
    await logger.close();
  });
}
