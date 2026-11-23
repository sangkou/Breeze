import 'package:flutter_test/flutter_test.dart';
import 'package:zephyr/network/http/plugin/unified_plugin_envelope.dart';
import 'package:zephyr/page/comic_info/models/unified_plugin_detail.dart';
import 'package:zephyr/page/comic_list/models/comic_list_scene.dart';
import 'package:zephyr/page/search_result/models/unified_plugin_search.dart';

void main() {
  const hostSource = 'dba2a6cf-c495-4416-accf-c29263ab4016';

  test('envelope uses host source instead of plugin source', () {
    final envelope = UnifiedPluginEnvelope.fromMap({
      'source': 'ehentai',
      'scheme': <String, dynamic>{},
      'data': <String, dynamic>{},
      'extern': <String, dynamic>{},
    }, source: hostSource);

    expect(envelope.source, hostSource);
  });

  test('comic list scene uses host source instead of plugin source', () {
    final scene = ComicListScene.fromMap({
      'title': '收藏',
      'source': 'ehentai',
      'body': {'request': <String, dynamic>{}},
    }, source: hostSource);

    expect(scene.from, hostSource);
  });

  test('comic detail response uses host source', () {
    final detail = UnifiedPluginDetailResponse.fromMap({
      'source': 'ehentai',
      'data': {'normal': <String, dynamic>{}, 'raw': <String, dynamic>{}},
    }, source: hostSource);

    expect(detail.source, hostSource);
  });

  test('search response uses host source', () {
    final response = UnifiedPluginSearchResponse.fromMap({
      'source': 'ehentai',
      'data': {'items': <dynamic>[], 'paging': <String, dynamic>{}},
    }, source: hostSource);

    expect(response.source, hostSource);
  });
}
