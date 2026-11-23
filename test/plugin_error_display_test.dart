import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zephyr/network/http/plugin/qjs_call_exception.dart';
import 'package:zephyr/network/http/plugin/unauthorized_payload.dart';
import 'package:zephyr/util/error/error_filter.dart';

void main() {
  test('simplify JS plugin error keeps Error: line only', () {
    const raw =
        'AnyhowException([bundle:bf99008d fn:getCloudFavoriteFilterBundle '
        'args:[{"extern":{"source":"bf99008d"}}] source:bf99008d.cjs] '
        '发送 HTTP 请求失败: error sending request for url '
        '(https://www.cdngwc.club/favorite?page=1): client error (Connect): '
        'tls handshake eof\n'
        '[stack-hook] Error: 发送 HTTP 请求失败: error sending request for url '
        '(https://www.cdngwc.club/favorite?page=1): client error (Connect): '
        'tls handshake eof\n'
        'at ew (<input>:3:13559)\n'
        'at from (<input>:3:13317)\n'
        'at (anonymous) (<input>:3:40991))';
    final out = simplifyPluginErrorText(raw);
    expect(
      out,
      'Error: 发送 HTTP 请求失败: error sending request for url '
      '(https://www.cdngwc.club/favorite?page=1): client error (Connect): '
      'tls handshake eof',
    );
    expect(out.contains('at ew'), isFalse);
    expect(out.contains('[bundle:'), isFalse);
  });

  test('simplify Rust-side error without stack strips scope prefix', () {
    const raw =
        '[bundle:abc fn:getList args:[] source:abc.cjs] '
        'failed to fetch: connection reset';
    expect(simplifyPluginErrorText(raw), 'failed to fetch: connection reset');
  });

  test('normalize respects simplify switch, parse always uses raw', () {
    const raw =
        'AnyhowException([bundle:pid fn:f args:[] source:pid.cjs] boom\n'
        '[stack-hook] Error: boom\n'
        'at x (<input>:1:2))';
    final error = AnyhowException(raw);

    setSimplifyPluginErrorDisplay(enabled: false);
    expect(normalizeSearchErrorMessage(error), raw.trim());

    setSimplifyPluginErrorDisplay(enabled: true);
    try {
      expect(normalizeSearchErrorMessage(error), 'Error: boom');
    } finally {
      setSimplifyPluginErrorDisplay(enabled: false);
    }

    // 登录解析不受展示开关影响：原文首行 JSON 照常识别。
    const loginRaw =
        '[bundle:pid fn:login args:[] source:pid.cjs] '
        '{"type":"unauthorized","source":"pid","message":"登录过期，请重新登录"}';
    setSimplifyPluginErrorDisplay(enabled: true);
    try {
      final payload = parseUnauthorizedPayload(
        AnyhowException(loginRaw),
        fallbackPluginId: 'fallback',
      );
      expect(payload, isNotNull);
      expect(payload!.pluginId, 'fallback');
      expect(payload.message, '登录过期，请重新登录');
    } finally {
      setSimplifyPluginErrorDisplay(enabled: false);
    }
  });

  test('unauthorized ignores plugin-reported short source', () {
    const loginMessage =
        '[bundle:dba2a6cf-c495-4416-accf-c29263ab4016 '
        'fn:getCloudFavoriteData args:[{"extern":{"favcat":"a","sort":"f"}}] '
        'source:dba2a6cf-c495-4416-accf-c29263ab4016.cjs] '
        '{"type":"unauthorized","source":"ehentai","message":"请先登录后再查看收藏"}';
    const invokedUuid = 'dba2a6cf-c495-4416-accf-c29263ab4016';

    final payload = parseUnauthorizedPayload(
      const QjsCallException(source: invokedUuid, message: loginMessage),
      fallbackPluginId: invokedUuid,
    );
    expect(payload!.pluginId, invokedUuid);
    expect(payload.message, '请先登录后再查看收藏');
  });

  test('extractPluginErrorRawText rejects non-AnyhowException', () {
    expect(extractPluginErrorRawText(AnyhowException('boom')), 'boom');
    expect(extractPluginErrorRawText(FormatException('bad')), isNull);
    expect(
      parseUnauthorizedPayload(
        FormatException('bad'),
        fallbackPluginId: 'fallback',
      ),
      isNull,
    );
  });
}
