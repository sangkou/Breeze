import 'dart:io';

import 'package:flutter/foundation.dart';

/// 当前是否运行在 OpenHarmony / HarmonyOS（Flutter OH fork）。
///
/// 官方 Flutter 没有 `Platform.isOhos`，只能比较 `operatingSystem`。
bool get isOhos => !kIsWeb && Platform.operatingSystem == 'ohos';
