import 'package:flutter/foundation.dart' show compute;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zephyr/network/sync/sync_device_id.dart';
import 'package:zephyr/util/rust/rust_loader.dart';

Future<String> _readDeviceIdInIsolate(String _) async {
  await initRustLib();
  return syncDeviceId;
}

void main() {
  test('子 isolate 通过 Rust 缓存读到主 isolate 初始化的设备 ID', () async {
    SharedPreferences.setMockInitialValues({});
    await initRustLib(silent: true);
    await ensureSyncDeviceId();

    final expected = syncDeviceId;
    expect(expected, isNot('device_default'));

    final fromIsolate = await compute(_readDeviceIdInIsolate, '');
    expect(fromIsolate, expected);
  });
}
