//! 同步设备 ID 的进程级缓存。
//! Process-wide cache for the sync device id.

use std::sync::RwLock;

use flutter_rust_bridge::frb;

/// 同步设备 ID 的进程级缓存。
///
/// 持久化仍在 Dart 侧（SharedPreferences）：应用启动时 Dart 读取或生成后写入这里。
/// Dart 的静态变量是 isolate 级的，后台 isolate（同步合并等）读不到；
/// 而同一进程里的所有 isolate 共享同一个原生库实例，所以它们可以从这里同步读取，
/// 不必在隔离区里异步访问平台通道（OHOS 的 prefs 通道只在主 isolate 注册）。
static SYNC_DEVICE_ID: RwLock<Option<String>> = RwLock::new(None);

/// 写入缓存的同步设备 ID。
///
/// 由主 isolate 在读取/生成设备 ID 后调用；重复调用以最后一次为准。
#[frb(sync)]
pub fn set_sync_device_id(id: String) {
    let mut guard = SYNC_DEVICE_ID
        .write()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    *guard = Some(id);
}

/// 读取缓存的同步设备 ID；主 isolate 尚未写入时返回 `None`。
#[frb(sync)]
pub fn sync_device_id() -> Option<String> {
    SYNC_DEVICE_ID
        .read()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .clone()
}
