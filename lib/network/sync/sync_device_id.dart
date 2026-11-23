import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:zephyr/src/rust/api/sync_device.dart' as rust_sync;

const String _prefsKey = 'sync.device_id';

String? _cachedDeviceId;

/// 初始化同步设备 ID：从 SharedPreferences 读取，不存在则生成 UUIDv4。
///
/// 只在主 isolate 启动时调用一次，并且必须在 `initRustLib()` 之后；拿到值后
/// 写入 Rust 侧进程级缓存，供读不到 Dart 静态变量的后台 isolate 使用。
/// 该 ID 只保存在本地，不同步到云端。
Future<void> ensureSyncDeviceId() async {
  final prefs = await SharedPreferences.getInstance();
  var id = prefs.getString(_prefsKey);
  if (id == null || id.isEmpty) {
    id = const Uuid().v4();
    await prefs.setString(_prefsKey, id);
  }
  _cachedDeviceId = id;
  rust_sync.setSyncDeviceId(id: id);
}

/// 同步获取设备 ID。
///
/// 当前 isolate 没有缓存时从 Rust 侧进程级缓存读取；都取不到时返回占位值
/// `device_default`。
String get syncDeviceId {
  final cached = _cachedDeviceId;
  if (cached != null && cached.isNotEmpty) return cached;

  final fromRust = rust_sync.syncDeviceId();
  if (fromRust != null && fromRust.isNotEmpty) {
    _cachedDeviceId = fromRust;
    return fromRust;
  }
  return 'device_default';
}

/// 直接设置当前 isolate 的 Dart 侧缓存。用于测试，不会写入 Rust 侧缓存。
set syncDeviceId(String value) {
  _cachedDeviceId = value;
}
