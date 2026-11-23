import 'package:flutter/services.dart';

import 'package:zephyr/util/ohos/platform.dart';

/// OHOS 系统通知发布（实现在 BreezeOhosPlugin）。
const MethodChannel _channel = MethodChannel('zephyr/ohos_file');

/// 发布一条系统通知；返回系统是否接受（未授权时为 false）。
Future<bool> publishOhosNotification({
  required int id,
  required String title,
  required String body,
}) async {
  if (!isOhos) {
    throw UnsupportedError('publishOhosNotification is OHOS-only');
  }
  return await _channel.invokeMethod<bool>('publishNotification', {
        'id': id,
        'title': title,
        'body': body,
      }) ??
      false;
}

/// 取消指定系统通知。
Future<void> cancelOhosNotification(int id) async {
  if (!isOhos) {
    throw UnsupportedError('cancelOhosNotification is OHOS-only');
  }
  await _channel.invokeMethod<void>('cancelNotification', {'id': id});
}
