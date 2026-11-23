import path from 'path'
import { injectNativeModules } from 'flutter-hvigor-plugin';

// flutter-hvigor-plugin 的 findFlutterPlugins 直接对
// `.flutter-plugins-dependencies` 的 `plugins.ohos` 调用 .filter()；该文件被官方
// Flutter 的 pub get 重写时不带 ohos 键，整个 hvigor 会以 “Syntax Error
// (hvigorconfig.ts)” 失败。本应用没有 OHOS 平台插件（走 app-level 实现），
// 注入失败可以安全跳过，不要因此中断打包。
try {
  injectNativeModules(__dirname, path.dirname(__dirname))
} catch (error) {
  console.warn('[flutter-hvigor-plugin] injectNativeModules skipped:', error)
}
