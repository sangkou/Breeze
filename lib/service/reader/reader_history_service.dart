import 'dart:async';
import 'dart:convert';

import 'package:zephyr/database/database.dart';
import 'package:zephyr/main.dart';
import 'package:zephyr/object_box/model.dart';
import 'package:zephyr/util/async/worker_pool.dart';
import 'package:zephyr/util/rust/rust_loader.dart';
import 'package:zephyr/page/comic_info/json/normal/normal_comic_all_info.dart'
    as normal;
import 'package:zephyr/page/comic_info/method/get_plugin_detail.dart';
import 'package:zephyr/page/comic_read/model/normal_comic_ep_info.dart';
import 'package:zephyr/service/reader/comic_read_chapter_repository.dart';

/// 供 [ReaderHistoryService] 周期性保存时使用的快照。
class HistorySnapshot {
  const HistorySnapshot({
    required this.pageIndex,
    required this.chapterOrder,
    required this.epInfo,
  });

  final int pageIndex;
  final int chapterOrder;
  final NormalComicEpInfo epInfo;
}

/// 阅读器历史记录服务。
///
/// 封装 ObjectBox 历史记录查询、后台写入与序列化逻辑，
/// 通过 [statusStream] 把左下角状态文本暴露给 controller，自身不依赖任何 cubit。
class ReaderHistoryService {
  static final ReaderHistoryService instance = ReaderHistoryService._();
  ReaderHistoryService._();

  final _statusController = StreamController<String>.broadcast();
  Stream<String> get statusStream => _statusController.stream;

  String? _source;
  String? _comicId;
  normal.ComicInfo? _comicInfo;
  UnifiedComicHistory? _history;
  Timer? _timer;
  DateTime? _lastUpdateTime;
  bool _isInserting = false;
  bool _isLoading = true;
  HistorySnapshot Function()? _snapshotProvider;
  String? _markedChapterId;

  String _cachedCoverJson = '';
  String _cachedCreatorJson = '';
  String _cachedTitleMetaJson = '';
  String _cachedMetadataJson = '';
  String _downloadTitle = '';
  String _downloadCover = '';
  bool _hasTitleOverride = false;
  bool _hasCoverOverride = false;
  DateTime? _lastOverrideRefresh;

  /// 加载指定漫画的历史记录，并解析 comicInfo 供后续写入使用。
  Future<void> loadHistory({
    required String source,
    required String comicId,
    required dynamic comicInfo,
  }) async {
    _source = source;
    _comicId = comicId;
    _comicInfo = await _resolveComicInfo(
      source: source,
      comicId: comicId,
      comicInfo: comicInfo,
    );
    _isLoading = true;
    _markedChapterId = null;

    _history = await database.histories.getByKey('$source:$comicId');

    final info = _comicInfo;
    if (info != null) {
      _cachedCoverJson = _normalizeWorkerFlexMapString(info.cover);
      _cachedCreatorJson = _normalizeWorkerFlexMapString(info.creator);
      _cachedTitleMetaJson = _normalizeWorkerFlexListString(info.titleMeta);
      _cachedMetadataJson = _normalizeWorkerMetadataString(info.metadata);
    }
    await _refreshDownloadOverrides();
    _lastOverrideRefresh = DateTime.now();
  }

  Future<void> _refreshDownloadOverrides() async {
    final source = _source;
    final comicId = _comicId;
    if (source == null || comicId == null) return;
    // 只取覆盖字段相关的轻量列：不把 chapters/detailJson 拉进 UI isolate。
    final rows = await database.downloads.getShelfByKeys(['$source:$comicId']);
    final download = rows.isEmpty ? null : rows.first;
    final active = download != null && !download.deleted;
    final titleOverride = active ? (download.titleOverride?.trim() ?? '') : '';
    final coverOverride = active ? (download.coverOverride?.trim() ?? '') : '';
    _hasTitleOverride = titleOverride.isNotEmpty;
    _hasCoverOverride = coverOverride.isNotEmpty;
    _downloadTitle = _hasTitleOverride ? download!.title : '';
    _downloadCover = _hasCoverOverride ? download!.cover : '';
  }

  /// 上次加载到的历史页码，未加载或为 null 时返回 0。
  int get lastPageIndex => _history?.pageIndex ?? 0;

  /// 标记数据加载完成，可以开始写入。
  void markLoaded() => _isLoading = false;

  /// 阅读器首屏就绪后立即记录当前章节已读。
  void markCurrentChapterRead() {
    final snapshot = _snapshotProvider?.call();
    if (snapshot == null) return;
    unawaited(_markChapterRead(snapshot.epInfo, snapshot.chapterOrder));
  }

  /// 章节切换时由周期保存顺带记录；同一章只写一次。
  Future<void> _markChapterRead(
    NormalComicEpInfo epInfo,
    int chapterOrder,
  ) async {
    final source = _source;
    final comicId = _comicId;
    final chapterId = epInfo.epId.trim();
    if (source == null || comicId == null || chapterId.isEmpty) return;
    if (_markedChapterId == chapterId) return;

    _markedChapterId = chapterId;
    try {
      await ComicReadChapterRepository.instance.markRead(
        source: source,
        comicId: comicId,
        chapterId: chapterId,
        chapterTitle: epInfo.epName,
        chapterOrder: chapterOrder,
      );
    } catch (e, s) {
      logger.w('mark chapter read failed', error: e);
      logger.d(s);
    }
  }

  /// 启动周期性保存。
  ///
  /// [provider] 由 controller 提供，用于在每次触发时获取当前阅读快照。
  void startPeriodicSave(HistorySnapshot Function() provider) {
    _snapshotProvider = provider;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      _writeHistory();
    });
  }

  /// 立即停止周期性保存。
  void stop() => _timer?.cancel();

  Future<void> _writeHistory() async {
    if (_isLoading || _comicInfo == null) return;
    if (_isInserting) return;
    if (_lastUpdateTime != null &&
        DateTime.now().difference(_lastUpdateTime!).inMilliseconds < 100) {
      return;
    }

    final snapshot = _snapshotProvider?.call();
    if (snapshot == null) return;

    await _markChapterRead(snapshot.epInfo, snapshot.chapterOrder);

    final currentTime = DateTime.now().toLocal().toString().substring(0, 19);
    _statusController.add(
      '${snapshot.chapterOrder > 0 ? '${snapshot.chapterOrder}-' : ''}'
      '${snapshot.epInfo.epName} / ${snapshot.pageIndex - 1} / $currentTime',
    );

    _isInserting = true;
    try {
      final now = DateTime.now();
      if (_lastOverrideRefresh == null ||
          now.difference(_lastOverrideRefresh!).inSeconds >= 10) {
        await _refreshDownloadOverrides();
        _lastOverrideRefresh = now;
      }

      final timestamp = now.toUtc();
      final source = _source!;
      final comicId = _comicId!;
      final info = _comicInfo!;
      final existing = _history;
      final title = _hasTitleOverride ? _downloadTitle : info.title;
      final effectiveCover = _hasCoverOverride
          ? _downloadCover
          : _cachedCoverJson;
      final nextCover = existing != null && _isLocalCover(existing.cover)
          ? existing.cover
          : effectiveCover;
      final entity =
          existing ??
          UnifiedComicHistory(
            uniqueKey: '$source:$comicId',
            source: source,
            comicId: comicId,
            title: title,
            description: info.description,
            cover: nextCover,
            creator: _cachedCreatorJson,
            titleMeta: _cachedTitleMetaJson,
            metadata: _cachedMetadataJson,
            chapterId: snapshot.epInfo.epId,
            chapterTitle: snapshot.epInfo.epName,
            chapterOrder: snapshot.chapterOrder,
            pageIndex: snapshot.pageIndex,
            createdAt: timestamp,
            lastReadAt: timestamp,
            updatedAt: timestamp,
            deleted: false,
            schemaVersion: 2,
          );

      entity
        ..title = title
        ..description = info.description
        ..cover = nextCover
        ..creator = _cachedCreatorJson
        ..titleMeta = _cachedTitleMetaJson
        ..metadata = _cachedMetadataJson
        ..chapterId = snapshot.epInfo.epId
        ..chapterTitle = snapshot.epInfo.epName
        ..chapterOrder = snapshot.chapterOrder
        ..pageIndex = snapshot.pageIndex
        ..lastReadAt = timestamp
        ..updatedAt = timestamp
        ..deleted = false;

      final id = await database.histories.putInWorker(entity);
      if (entity.id != id) entity.id = id;
      _history = entity;
    } catch (e, s) {
      logger.w('后台写入历史记录失败', error: e);
      logger.d(s);
    } finally {
      _isInserting = false;
      _lastUpdateTime = DateTime.now();
    }
  }

  /// 下载记录只取 detailJson，并在后台 isolate 内解析成 ComicInfo。
  Future<normal.ComicInfo> _resolveComicInfo({
    required String source,
    required String comicId,
    required dynamic comicInfo,
  }) async {
    if (comicInfo is UnifiedComicDownload) {
      final handle = database.db.handle;
      final info = await runInIsolate(
        _resolveDownloadComicInfoInWorker,
        _HistoryDetailTask(handle: handle, downloadKey: '$source:$comicId'),
      );
      if (info == null) {
        throw StateError('本地下载信息不存在: $source:$comicId');
      }
      return info;
    }
    return _resolveNormalComicInfo(comicInfo);
  }

  normal.ComicInfo _resolveNormalComicInfo(dynamic comicInfo) {
    if (comicInfo is PluginComicDetailSource) {
      return comicInfo.normalInfo.comicInfo;
    }
    final map = _toDynamicMap(comicInfo);
    final comicInfoMap = _toDynamicMap(map['comicInfo']);
    if (comicInfoMap.isNotEmpty) {
      return normal.ComicInfo.fromJson(comicInfoMap);
    }
    if (_looksLikeComicInfoMap(map)) {
      return normal.ComicInfo.fromJson(map);
    }

    throw StateError('Unsupported comicInfo type: ${comicInfo.runtimeType}');
  }

  Map<String, dynamic> _toDynamicMap(dynamic value) {
    if (value is Map<String, dynamic>) {
      return value;
    }
    if (value is Map) {
      return Map<String, dynamic>.from(value);
    }
    try {
      final normalized = jsonDecode(jsonEncode(value));
      if (normalized is Map) {
        return Map<String, dynamic>.from(normalized);
      }
    } catch (_) {}
    return const <String, dynamic>{};
  }

  bool _looksLikeComicInfoMap(Map<String, dynamic> map) {
    return map['id'] != null &&
        map['title'] != null &&
        map['cover'] is Map &&
        map['creator'] is Map;
  }
}

class _HistoryDetailTask {
  const _HistoryDetailTask({required this.handle, required this.downloadKey});

  final int handle;
  final String downloadKey;
}

/// 只读 detailJson 并解析：阅读页打开时那次 2ms 的同步解析移到这里。
Future<normal.ComicInfo?> _resolveDownloadComicInfoInWorker(
  _HistoryDetailTask task,
) async {
  await initRustLib();
  final detailJson = await Database.fromHandle(task.handle).downloads
      .getDetailJson(task.downloadKey);
  if (detailJson == null || detailJson.isEmpty) return null;
  final detail = jsonDecode(detailJson) as Map<String, dynamic>;
  return normal.NormalComicAllInfo.fromJson(detail).comicInfo;
}

bool _isLocalCover(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map) {
      final extern = decoded['extern'];
      return extern is Map && extern['local'] == true;
    }
  } catch (_) {}
  return false;
}

Map<String, dynamic> _normalizeWorkerFlexMap(dynamic value) {
  final encoded = jsonEncode(value);
  final decoded = jsonDecode(encoded);
  if (decoded is Map) {
    return Map<String, dynamic>.from(decoded);
  }
  return <String, dynamic>{};
}

List<Map<String, dynamic>> _normalizeWorkerFlexList(List<dynamic> value) {
  final encoded = jsonEncode(value);
  final decoded = jsonDecode(encoded);
  if (decoded is List) {
    return decoded
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }
  return <Map<String, dynamic>>[];
}

String _normalizeWorkerFlexMapString(dynamic value) {
  return jsonEncode(_normalizeWorkerFlexMap(value));
}

String _normalizeWorkerFlexListString(List<dynamic> value) {
  return jsonEncode(_normalizeWorkerFlexList(value));
}

String _normalizeWorkerMetadataString(List<dynamic> value) {
  final normalized = _normalizeWorkerFlexList(value);
  return jsonEncode(normalized);
}
