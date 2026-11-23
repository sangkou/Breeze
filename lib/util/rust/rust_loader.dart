import 'package:zephyr/src/rust/frb_generated.dart';

bool _rustLibReady = false;
Future<void>? _rustLibInit;

/// 幂等初始化 FRB。
///
/// 应用启动、数据库打开、后台回调都可能调用；FRB 的 `RustLib.init()`
/// 第二次调用会抛 "Should not initialize ... twice"，这里统一吞掉。
Future<void> initRustLib({bool silent = false}) {
  if (_rustLibReady) return Future<void>.value();
  return _rustLibInit ??= _doInit(silent).whenComplete(() {
    if (!_rustLibReady) _rustLibInit = null;
  });
}

Future<void> _doInit(bool silent) async {
  try {
    await RustLib.init();
    _rustLibReady = true;
  } catch (error) {
    if (error.toString().contains('twice')) {
      _rustLibReady = true;
      return;
    }
    if (!silent) rethrow;
  }
}
