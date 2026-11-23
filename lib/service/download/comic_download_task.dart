import 'dart:async';
import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:zephyr/config/global/global.dart';
import 'package:zephyr/main.dart';
import 'package:zephyr/network/http/plugin/qjs_download_runtime.dart';
import 'package:zephyr/object_box/model.dart';
import 'package:zephyr/page/comic_info/json/normal/normal_comic_all_info.dart'
    as normal;
import 'package:zephyr/page/comic_info/method/get_plugin_detail.dart';
import 'package:zephyr/page/comic_read/model/unified_plugin_chapter.dart';
import 'package:zephyr/page/download/adapters/download_chapter_adapter.dart';
import 'package:zephyr/page/download/models/download_chapter.dart';
import 'package:zephyr/page/download/models/unified_comic_download.dart';
import 'package:zephyr/service/download/download_cancel_signal.dart';
import 'package:zephyr/service/download/download_asset_store.dart';
import 'package:zephyr/service/download/download_progress_reporter.dart';
import 'package:zephyr/service/download/download_retry.dart';
import 'package:zephyr/service/download/download_task_repository.dart';
import 'package:zephyr/service/download/models/download_task_json.dart';
import 'package:zephyr/i18n/strings.g.dart';
import 'package:zephyr/service/download/image_download.dart';
import 'package:zephyr/network/sync/sync_device_id.dart';
import 'package:zephyr/src/rust/api/simple.dart';
import 'package:zephyr/util/async/worker_pool.dart';
import 'package:zephyr/util/storage/get_path.dart';

/// 单章节下载任务。
///
/// 每个任务只下载一个章节：先确认本地有无本漫画记录（没有则取详情 + 下封面，
/// 成功后连章节一起入库），再取章节、逐图下载、提交。已落盘的图片直接复用，
/// 因此中断恢复不需要章节内 checkpoint。
Future<void> unifiedDownloadTask(
  DownloadProgressReporter reporter,
  DownloadTaskJson task,
) async {
  logger.d('unifiedDownloadTask received taskKey=${task.taskKey}');
  final pluginId = (task.from).trim();
  final from = pluginId;
  var comicId = task.comicId;
  final runtimeName = runtimeNameForPluginId(pluginId);
  final taskKey = task.taskKey;
  const taskRepository = DownloadTaskRepository();
  // 设置在整个任务生命周期内只读一次：下载循环里传的是同步回调。
  final retryUntilSuccess =
      (await database.userSettings.get())
          ?.globalSetting
          .retryDownloadUntilSuccess ??
      false;
  bool shouldRetryUntilSuccess() => retryUntilSuccess;

  Timer? progressTimer;
  bool running = true;
  // 1s Timer 与逐图 ensureTaskRunning 都会读库；状态未变时跳过写、存活检查
  // 1s 节流。取消仍走同步的 cancel signal，不依赖这里。
  String? lastEnqueuedStatus;
  DateTime? lastLivenessCheck;

  Future<DownloadTask?> findCurrentTask() async {
    final current = await taskRepository.findByTaskKey(taskKey);
    if (current == null || !current.isDownloading) return null;
    return current;
  }

  Future<void> writeTaskStatus(String status) async {
    if (status == lastEnqueuedStatus) return;
    lastEnqueuedStatus = status;
    final dbTask = await findCurrentTask();
    if (dbTask == null) return;
    // 高频状态同步走后台写，避免阻塞下载循环。
    await taskRepository.putTaskWriteBackground(
      taskKey: taskKey,
      taskId: dbTask.id,
      status: status,
    );
  }

  void updateTaskStatus(String status) {
    unawaited(writeTaskStatus(status));
  }

  Future<void> updateCheckpoint(
    DownloadTaskJson Function(DownloadTaskJson payload) update, {
    String? status,
  }) async {
    final dbTask = await taskRepository.findByTaskKey(taskKey);
    if (dbTask == null) return;
    // payload 在主线程拼好，写库时只覆盖 payload / status；串行排队保证有序。
    final payload = taskRepository.readPayload(dbTask) ?? task;
    final next = update(payload);
    await taskRepository.putTaskWriteBackground(
      taskKey: taskKey,
      taskId: dbTask.id,
      status: status,
      payloadJson: downloadTaskJsonToJson(next),
    );
  }

  Future<DownloadTaskJson> currentPayload() async {
    final current = await taskRepository.findByTaskKey(taskKey);
    return taskRepository.readPayload(current ?? DownloadTask()) ?? task;
  }

  Future<void> ensureTaskRunning() async {
    final signaled = isDownloadCancelSignaled(taskKey);
    if (!signaled) {
      // 每张图都走一次 DB 读（含 payload 解析 + worker isolate spawn）成本高；
      // 取消有同步信号兜底，库检查 1s 一次即可。
      final now = DateTime.now();
      final last = lastLivenessCheck;
      if (last != null && now.difference(last) < const Duration(seconds: 1)) {
        return;
      }
      final currentTask = await findCurrentTask();
      if (currentTask != null) {
        lastLivenessCheck = now;
        return;
      }
    }
    logger.w(
      'ensureTaskRunning 取消任务: taskKey=$taskKey, signaled=$signaled, 任务不存在或已停止',
    );
    await cancelTrackedQjsTasks(pluginId: pluginId, taskGroupKey: taskKey);
    throw const DownloadTaskCancelledException();
  }

  const adapter = DownloadChapterAdapter();
  final chapter = adapter.fromTaskRef(task.chapterRef);
  // 上次尝试已落盘的图片路径：恢复时会快速复用，取消时需要一并清理。
  final completedPaths = <String>{...(await currentPayload()).imagePaths};
  // 真 404 而跳过的图片路径：落库时打标记，不计失败。
  final skippedPaths = <String>{};

  Future<void> deleteChapterFiles() async {
    await DownloadAssetStore.deleteDownloadedFiles(
      from: from,
      cartoonId: comicId,
      effectiveStorageChapterId: chapter.effectiveStorageId,
      docPaths: completedPaths,
    );
  }

  try {
    await ensureQjsRuntimeReady(pluginId: pluginId);
    await ensureTaskRunning();
    await updateCheckpoint(
      (payload) =>
          payload.copyWith(stateCode: 'running', phaseCode: 'preparingRuntime'),
    );
    await preparePluginDownloadRuntime(
      from: from,
      pluginId: pluginId,
      runtimeName: runtimeName,
      taskGroupKey: taskKey,
    );

    // 本地已有本漫画记录时跳过详情和封面，直下本章。
    var existing = await taskRepository.findDownloadRecord(from, comicId);
    late normal.NormalComicAllInfo normalInfo;
    List<Map<String, dynamic>>? onlineCatalog;
    if (existing == null) {
      await updateCheckpoint(
        (payload) => payload.copyWith(
          phaseCode: 'fetchingComicInfo',
          lastErrorCode: '',
          lastErrorMessage: '',
        ),
        status: t.download.statusFetchingComicInfo,
      );
      updateTaskStatus(t.download.statusFetchingComicInfo);
      reporter.updateMessage(t.download.statusFetchingComicInfo);
      final detail = await getComicDetailByPlugin(
        comicId,
        from,
        pluginId: pluginId,
      );
      comicId = detail.comicId;

      updateTaskStatus(t.download.statusDownloadingCover);
      await updateCheckpoint(
        (payload) => payload.copyWith(phaseCode: 'downloadingCover'),
        status: t.download.statusDownloadingCover,
      );
      reporter.updateMessage(t.download.statusDownloadingCover);
      final cover = detail.normalInfo.comicInfo.cover;
      final coverExtension = Map<String, dynamic>.from(cover.extern);
      final rawCoverFileName = cover.path.trim().isNotEmpty
          ? cover.path
          : coverExtension['path']?.toString() ?? '';
      String coverPath = '404';
      if (rawCoverFileName.trim().isNotEmpty && cover.url.trim().isNotEmpty) {
        final coverFileName = normalizeStoredAssetPath(rawCoverFileName);
        coverPath = await downloadCoverAsset(
          from: from,
          url: cover.url,
          path: coverFileName,
          cartoonId: comicId,
          qjsName: runtimeName,
          qjsTaskGroupKey: taskKey,
          shouldRetryUntilSuccess: shouldRetryUntilSuccess,
        );
      }

      // 首存：把全量在线目录快照一起带上（显示排序与下载校验用）。
      onlineCatalog = buildChapterCatalog(detail.normalInfo.eps);
      normalInfo = detail.normalInfo.copyWith(recommend: const []);
      if (coverPath.startsWith('404')) {
        final clearedCoverExtension = {
          ...normalInfo.comicInfo.cover.extern,
          'path': '',
        };
        normalInfo = normalInfo.copyWith(
          comicInfo: normalInfo.comicInfo.copyWith(
            cover: normalInfo.comicInfo.cover.copyWith(
              url: '',
              path: '',
              extern: clearedCoverExtension,
            ),
          ),
        );
      }
    } else {
      normalInfo = normal.NormalComicAllInfo.fromJson(
        jsonDecode(existing.detailJson) as Map<String, dynamic>,
      );
      // 追加：本章不在目录快照里说明快照过期，重拉一次刷新。失败不阻塞下载。
      onlineCatalog = readChapterCatalogMaps(existing);
      final catalogChapters = readChapterCatalog(existing);
      final inCatalog = catalogChapters.any(
        (entry) => downloadChapterIdentityMatches(entry, chapter),
      );
      if (!inCatalog) {
        try {
          final fresh = await getComicDetailByPlugin(
            comicId,
            from,
            pluginId: pluginId,
          );
          onlineCatalog = buildChapterCatalog(fresh.normalInfo.eps);
          final decoded = jsonDecode(existing.detailJson);
          if (decoded is Map) {
            final detailMap = Map<String, dynamic>.from(decoded);
            final extern = Map<String, dynamic>.from(
              detailMap['extern'] as Map? ?? const {},
            );
            extern['chapterCatalog'] = onlineCatalog;
            detailMap['extern'] = extern;
            existing
              ..detailJson = jsonEncode(detailMap)
              ..updatedAt = DateTime.now().toUtc();
            await database.downloads.put(existing);
          }
          logger.i('下载目录快照已刷新: $from:$comicId');
        } catch (e) {
          logger.w('下载目录快照刷新失败，继续下载: $from:$comicId', error: e);
        }
      }
    }

    progressTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (running) {
        updateTaskStatus(reporter.message);
      }
    });

    await ensureTaskRunning();
    updateTaskStatus(t.download.statusFetchingChapterInfo);
    reporter.updateMessage(t.download.statusFetchingChapterInfo);
    await updateCheckpoint(
      (payload) => payload.copyWith(
        stateCode: 'running',
        phaseCode: 'fetchingChapterInfo',
        completedImages: 0,
        reusedImages: 0,
        totalImages: 0,
      ),
    );

    final requestChapterId = chapter.effectiveRequestId;
    final chapterExtern = Map<String, dynamic>.from(chapter.extern);
    logger.d(
      'download getChapter plugin=$pluginId comicId=$comicId chapter.id=${chapter.id} order=${chapter.order} requestChapterId=$requestChapterId storageChapterId=${chapter.effectiveStorageId} extern=$chapterExtern',
    );
    final response = await retryDownloadOperation<UnifiedPluginChapterResponse>(
      operation: '获取章节 ${chapter.displayName}',
      ensureTaskRunning: ensureTaskRunning,
      shouldRetryUntilSuccess: shouldRetryUntilSuccess,
      action: () => _getChapterByPlugin(
        from: from,
        pluginId: pluginId,
        comicId: comicId,
        chapterId: requestChapterId,
        runtimeName: runtimeName,
        extern: {...chapterExtern, 'chapterId': requestChapterId},
      ),
    );
    final jobs = <DownloadImageJob>[];
    for (final doc in response.chapter.docs) {
      jobs.add(
        DownloadImageJob(
          url: doc.url,
          path: doc.path,
          cartoonId: comicId,
          chapterId: response.chapter.epId,
          storageChapterId: chapter.effectiveStorageId,
          extern: doc.extern,
        ),
      );
    }

    await updateCheckpoint(
      (payload) => payload.copyWith(
        phaseCode: 'downloadingChapter',
        totalImages: jobs.length,
      ),
    );
    reporter.updateMessage(t.download.statusDownloadProgress(percent: 0));

    var lastPersistedImages = 0;
    var lastPersistedAt = DateTime.now();
    var lastReportedPercent = -1;
    try {
      await downloadImageJobs(
        from: from,
        jobs: jobs,
        qjsRuntimeName: runtimeName,
        qjsTaskGroupKey: taskKey,
        ensureTaskRunning: ensureTaskRunning,
        shouldRetryUntilSuccess: shouldRetryUntilSuccess,
        reporter: reporter,
        concurrency: await resolveDownloadConcurrency(
          from: from,
          pluginId: pluginId,
        ),
        onProgress:
            (completed, downloaded, reused, completedJob, jobSkipped) async {
              if (completedJob.path.trim().isNotEmpty) {
                completedPaths.add(completedJob.path);
                // 真 404 的图记下来，落库时打跳过标记（不再按失败处理）。
                if (jobSkipped) skippedPaths.add(completedJob.path);
              }
              final currentPercent = jobs.isEmpty
                  ? 100
                  : (completed / jobs.length * 100).floor();
              if (currentPercent > lastReportedPercent ||
                  completed == jobs.length) {
                lastReportedPercent = currentPercent;
                final message = t.download.statusDownloadProgress(
                  percent: currentPercent,
                );
                // 进度只走内存 + 通知流，不写库（1s Timer 负责同步 status）。
                // 之前这里每张图写库，主线程约 13ms，是卡顿主因。
                reporter.updateMessage(message);
              }

              final now = DateTime.now();
              final shouldPersist =
                  completed == jobs.length ||
                  completed - lastPersistedImages >= 5 ||
                  now.difference(lastPersistedAt) >= const Duration(seconds: 1);
              if (!shouldPersist) return;
              lastPersistedImages = completed;
              lastPersistedAt = now;
              await updateCheckpoint(
                (payload) => payload.copyWith(
                  completedImages: completed,
                  reusedImages: reused,
                  totalImages: jobs.length,
                  imagePaths: completedPaths.toList(),
                ),
              );
            },
      );
    } on DownloadTaskCancelledException {
      // 取消本章：删掉已下的散图后继续向上抛，队列会删任务记录并继续下一章。
      await deleteChapterFiles();
      rethrow;
    }

    await updateCheckpoint(
      (payload) => payload.copyWith(phaseCode: 'committingChapter'),
    );
    await _saveUnifiedDownloadChapter(
      from: from,
      comicId: comicId,
      normalInfo: normalInfo,
      selectedChapter: chapter,
      chapterResponse: response,
      onlineCatalog: onlineCatalog,
      skippedPaths: skippedPaths,
    );

    await updateCheckpoint(
      (payload) => payload.copyWith(
        stateCode: 'completed',
        phaseCode: 'completed',
        completedImages: jobs.length,
        totalImages: jobs.length,
        imagePaths: completedPaths.toList(),
      ),
    );
    reporter.updateMessage(t.download.statusDownloadProgressComplete);
    await _markTaskCompleted(taskKey);
  } on DownloadTaskCancelledException {
    // 检查点之间的取消同样要清理散图。
    await deleteChapterFiles();
    rethrow;
  } finally {
    running = false;
    progressTimer?.cancel();
  }
}

Future<UnifiedPluginChapterResponse> _getChapterByPlugin({
  required String from,
  required String pluginId,
  required String comicId,
  required String chapterId,
  required String runtimeName,
  required Map<String, dynamic> extern,
}) async {
  return getComicChapterByPlugin(
    comicId,
    chapterId,
    from,
    pluginId: pluginId,
    runtimeName: runtimeName,
    extern: extern,
  );
}

Future<void> _saveUnifiedDownloadChapter({
  required String from,
  required String comicId,
  required normal.NormalComicAllInfo normalInfo,
  required DownloadChapter selectedChapter,
  required UnifiedPluginChapterResponse chapterResponse,
  List<Map<String, dynamic>>? onlineCatalog,
  Set<String> skippedPaths = const {},
}) async {
  final now = DateTime.now().toUtc();
  final key = buildDownloadTaskKey(from, comicId);
  final existing = await database.downloads.getByKey(key);
  final downloadPath = await getDownloadPath();
  // JSON 拼装是纯计算，走后台 isolate；主线程只做 put。
  final buildArgs = <String, dynamic>{
    'normalInfo': normalInfo.toJson(),
    'existing': existing == null
        ? null
        : {
            'cover': existing.cover,
            'chapters': existing.chapters,
            'detailJson': existing.detailJson,
            'titleOverride': existing.titleOverride,
            'coverOverride': existing.coverOverride,
          },
    'selected': {
      'id': selectedChapter.id,
      'displayName': selectedChapter.displayName,
      'order': selectedChapter.order,
      'requestId': selectedChapter.requestId,
      'storageId': selectedChapter.storageId,
      'groupTitle': selectedChapter.groupTitle,
      'extern': Map<String, dynamic>.from(selectedChapter.extern),
    },
    'docs': chapterResponse.chapter.docs.map((d) => d.toMap()).toList(),
    'epId': chapterResponse.chapter.epId,
    'epName': chapterResponse.chapter.epName,
    'from': from,
    'comicId': comicId,
    'mainVersion': mainVersion,
    'onlineCatalog': onlineCatalog,
    'skippedPaths': skippedPaths.toList(),
  };
  final built = await runInIsolate(_buildDownloadRecordJson, buildArgs);

  // 记录落库 + 根目录下载链接同事务提交。
  final record = UnifiedComicDownload(
    id: existing?.id ?? 0,
    uniqueKey: key,
    source: from,
    comicId: comicId,
    title: built['title'] as String,
    description: built['description'] as String,
    cover: built['cover'] as String,
    titleOverride: built['titleOverride'] as String?,
    coverOverride: built['coverOverride'] as String?,
    creator: built['creator'] as String,
    titleMeta: built['titleMeta'] as String,
    metadata: built['metadata'] as String,
    totalViews: built['totalViews'] as int,
    totalLikes: built['totalLikes'] as int,
    totalComments: built['totalComments'] as int,
    isFavourite: built['isFavourite'] as bool,
    isLiked: built['isLiked'] as bool,
    allowComment: built['allowComment'] as bool,
    allowLike: built['allowLike'] as bool,
    allowFavorite: built['allowFavorite'] as bool,
    allowDownload: built['allowDownload'] as bool,
    chapters: built['chapters'] as String,
    detailJson: built['detail'] as String,
    storageRoot: p.join(
      downloadPath,
      encodePath(path: normalizePluginId(from)),
      encodePath(path: comicId),
    ),
    createdAt: existing?.createdAt ?? now,
    updatedAt: now,
    downloadedAt: now,
    deleted: false,
    schemaVersion: 2,
  );
  await database.downloadTasks.saveDownloadRecordWithRootLink(
    record: record,
    linkUniqueKey: '$key||${ComicFolderType.download.name}',
    linkComicKey: key,
    deviceId: syncDeviceId,
  );
}

/// 后台 isolate 里拼下载记录 JSON（纯计算，无 DB/IO/logger）。
Map<String, dynamic> _buildDownloadRecordJson(Map<String, dynamic> args) {
  final normalInfo = normal.NormalComicAllInfo.fromJson(
    Map<String, dynamic>.from(args['normalInfo'] as Map),
  );
  final existingRaw = args['existing'] as Map?;
  final titleOverride = existingRaw?['titleOverride']?.toString().trim() ?? '';
  final coverOverride = existingRaw?['coverOverride']?.toString().trim() ?? '';
  final selectedRaw = Map<String, dynamic>.from(args['selected'] as Map);
  final selected = DownloadChapter(
    id: selectedRaw['id'] as String,
    displayName: selectedRaw['displayName'] as String,
    order: selectedRaw['order'] as int,
    requestId: selectedRaw['requestId'] as String?,
    storageId: selectedRaw['storageId'] as String?,
    groupTitle: selectedRaw['groupTitle'] as String? ?? '',
    extern: Map<String, dynamic>.from(selectedRaw['extern'] as Map),
    images: const [],
  );
  final docs = (args['docs'] as List)
      .map(
        (m) => UnifiedPluginChapterDoc.fromMap(
          Map<String, dynamic>.from(m as Map),
        ),
      )
      .toList();
  final response = UnifiedPluginChapterResponse(
    source: '',
    comicId: '',
    chapterId: '',
    extern: const {},
    scheme: const {},
    chapter: UnifiedPluginChapter(
      epId: args['epId'] as String,
      epName: args['epName'] as String,
      order: 0,
      length: docs.length,
      epPages: docs.length.toString(),
      docs: docs,
      extern: const {},
    ),
  );

  final storedChapters = existingRaw == null
      ? <UnifiedComicDownloadStoredChapter>[]
      : resolveStoredDownloadChaptersFromJson(
          chaptersJson: existingRaw['chapters'] as String,
          detailJson: existingRaw['detailJson'] as String,
        ).toList();
  final skippedPaths = ((args['skippedPaths'] as List?) ?? const [])
      .map((e) => normalizeStoredAssetPath(e.toString()))
      .toSet();
  final storedChapter = _buildStoredChapter(
    selected,
    response,
    skippedPaths: skippedPaths,
  );
  final existingIndex = storedChapters.indexWhere(
    (item) => _storedChapterMatches(item, selected),
  );
  if (existingIndex >= 0) {
    storedChapters[existingIndex] = storedChapter;
  } else {
    storedChapters.add(storedChapter);
  }
  storedChapters.sort((a, b) => a.order.compareTo(b.order));

  final eps = buildDownloadEps(storedChapters);
  final onlineCatalog = args['onlineCatalog'] as List?;
  final detail = normalInfo.copyWith(
    eps: eps,
    recommend: const [],
    extern: {
      ...normalInfo.extern,
      if (onlineCatalog != null)
        'chapterCatalog': onlineCatalog
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList(),
      'downloadChapters': storedChapters.map((e) => e.toMap()).toList(),
    },
  );
  var coverMap = _normalizeStoredImageMap(
    _deepCopyMap(detail.comicInfo.cover.toJson()),
  );
  if (_isEmptyStoredImage(coverMap) && existingRaw != null) {
    try {
      coverMap = _normalizeStoredImageMap(
        Map<String, dynamic>.from(
          jsonDecode(existingRaw['cover'] as String) as Map,
        ),
      );
    } catch (e, st) {
      logger.e(e, stackTrace: st);
      // 旧记录封面 JSON 损坏时继续使用当前详情的空封面。
    }
  }
  final creatorMap = _normalizeStoredCreatorMap(
    _deepCopyMap(detail.comicInfo.creator.toJson()),
  );
  final titleMeta = _deepCopyMapList(
    detail.comicInfo.titleMeta.map((e) => e.toJson()).toList(),
  );
  final metadata = _normalizeMetadataForStorage(detail.comicInfo.metadata);
  final chapters = storedChapters.map((chapter) => chapter.toMap()).toList();

  final effectiveTitle = titleOverride.isNotEmpty
      ? titleOverride
      : detail.comicInfo.title;
  final effectiveCover = coverOverride.isNotEmpty
      ? coverOverride
      : jsonEncode(coverMap);

  return <String, dynamic>{
    'title': effectiveTitle,
    'description': detail.comicInfo.description,
    'cover': effectiveCover,
    'titleOverride': titleOverride.isEmpty ? null : titleOverride,
    'coverOverride': coverOverride.isEmpty ? null : coverOverride,
    'creator': jsonEncode(creatorMap),
    'titleMeta': jsonEncode(titleMeta),
    'metadata': metadata,
    'totalViews': detail.totalViews,
    'totalLikes': detail.totalLikes,
    'totalComments': detail.totalComments,
    'isFavourite': detail.isFavourite,
    'isLiked': detail.isLiked,
    'allowComment': detail.allowComments,
    'allowLike': detail.allowLike,
    'allowFavorite': detail.allowCollected,
    'allowDownload': detail.allowDownload,
    'chapters': jsonEncode(chapters),
    'detail': jsonEncode(
      detail
          .copyWith(extern: {...detail.extern, 'version': args['mainVersion']})
          .toJson(),
    ),
    'imageCount': storedChapter.images.length,
    'storedCount': storedChapters.length,
  };
}

UnifiedComicDownloadStoredChapter _buildStoredChapter(
  DownloadChapter selectedChapter,
  UnifiedPluginChapterResponse response, {
  Set<String> skippedPaths = const {},
}) {
  // 注意：此函数会在后台 isolate 里运行，不要在这里打 logger/碰 IO。
  return UnifiedComicDownloadStoredChapter(
    // `id` 字段保持为本地存储 key，旧版本读取时仍按 storage key 理解。
    id: selectedChapter.effectiveStorageId,
    name: selectedChapter.displayName.trim().isNotEmpty
        ? selectedChapter.displayName
        : response.chapter.epName,
    order: selectedChapter.order,
    // `logicalKey` 写入宿主匹配 key，保证新版本通过适配器能还原出正确的 id。
    logicalKey: selectedChapter.id,
    taskChapterId: selectedChapter.effectiveRequestId,
    // 显式保存 storageChapterId，确保显式指定了 storage key 的插件能正确还原。
    storageChapterId: selectedChapter.effectiveStorageId,
    groupTitle: selectedChapter.groupTitle,
    images: response.chapter.docs.map((doc) {
      final imageName = _resolveImageDisplayName(doc);
      final imagePath = normalizeStoredAssetPath(doc.path);
      // 真 404 而跳过的图打标记：阅读器显示缺图占位，导出不再补下。
      final skipped = skippedPaths.contains(imagePath);
      return UnifiedComicDownloadImage(
        id: doc.id.isNotEmpty
            ? doc.id
            : _fallbackImageId(doc, response.chapter.epId),
        name: imageName,
        path: imagePath,
        url: doc.url,
        extern: skipped ? {...doc.extern, 'downloadSkipped': true} : doc.extern,
      );
    }).toList(),
  );
}

/// 章节身份只认 logical / request 系 key，storage 系 key
///（多分块可共享，如 EH 的 "Gallery"）绝不能作为判同依据。
bool _storedChapterMatches(
  UnifiedComicDownloadStoredChapter stored,
  DownloadChapter selected,
) {
  final storedIdentity = <String>{
    stored.logicalKey.trim(),
    stored.taskChapterId.trim(),
  }..remove('');
  if (storedIdentity.isEmpty && stored.storageChapterId.trim().isEmpty) {
    // 纯老数据：没有任何插件化字段时，id 才是匹配 key。
    final legacyId = stored.id.trim();
    if (legacyId.isNotEmpty) storedIdentity.add(legacyId);
  }
  final selectedIdentity = <String>{
    selected.id.trim(),
    selected.effectiveRequestId.trim(),
  }..remove('');
  if (storedIdentity.intersection(selectedIdentity).isNotEmpty) return true;
  // order 不再单独作为判同依据；双方都没有身份 key 时才用它兜底。
  return storedIdentity.isEmpty &&
      selectedIdentity.isEmpty &&
      stored.order > 0 &&
      stored.order == selected.order;
}

bool _isEmptyStoredImage(Map<String, dynamic> image) {
  final path = image['path']?.toString().trim() ?? '';
  final extern = Map<String, dynamic>.from(image['extern'] as Map? ?? const {});
  final externPath = extern['path']?.toString().trim() ?? '';
  return path.isEmpty && externPath.isEmpty;
}

Map<String, dynamic> _deepCopyMap(Object value) {
  final encoded = jsonEncode(value);
  final decoded = jsonDecode(encoded);
  return Map<String, dynamic>.from(decoded as Map);
}

List<Map<String, dynamic>> _deepCopyMapList(Object value) {
  final encoded = jsonEncode(value);
  final decoded = jsonDecode(encoded) as List;
  return decoded.map((item) => Map<String, dynamic>.from(item as Map)).toList();
}

String _normalizeMetadataForStorage(List<normal.ComicInfoMetadata> metadata) {
  final normalized = <Map<String, dynamic>>[];
  for (final item in metadata) {
    final values = item.value
        .map((entry) => entry.name.trim())
        .where((entry) => entry.isNotEmpty)
        .map((entry) => {'name': entry})
        .toList();
    if (values.isEmpty) {
      continue;
    }
    normalized.add({'type': item.type, 'name': item.name, 'value': values});
  }
  return jsonEncode(normalized);
}

String _fallbackImageId(UnifiedPluginChapterDoc doc, String chapterId) {
  final candidate = doc.path.isNotEmpty ? doc.path : doc.name;
  final base = candidate.split(RegExp(r'[\\/]')).last.trim();
  final withoutExt = base.contains('.')
      ? base.substring(0, base.lastIndexOf('.'))
      : base;
  if (withoutExt.isNotEmpty) {
    return withoutExt.replaceAll(RegExp(r'[^a-zA-Z0-9_\-.]'), '_');
  }
  return '${chapterId}_${doc.id.hashCode.abs()}';
}

String _resolveImageDisplayName(UnifiedPluginChapterDoc doc) {
  if (doc.name.trim().isNotEmpty) {
    return doc.name.trim();
  }
  final pathName = p.basename(doc.path.trim());
  if (pathName.isNotEmpty) {
    return pathName;
  }
  return 'asset.bin';
}

Map<String, dynamic> _normalizeStoredImageMap(Map<String, dynamic> image) {
  final map = Map<String, dynamic>.from(image);
  final ext = Map<String, dynamic>.from(map['extern'] as Map? ?? const {});
  final topLevelRawPath = map['path']?.toString() ?? '';
  final extRawPath = ext['path']?.toString() ?? '';

  final normalizedTopLevelPath = normalizeStoredAssetPath(
    topLevelRawPath,
    allowEmpty: true,
  );
  final normalizedExtPath = normalizeStoredAssetPath(
    extRawPath,
    allowEmpty: true,
  );
  final mergedPath = normalizedTopLevelPath.isNotEmpty
      ? normalizedTopLevelPath
      : normalizedExtPath;

  map['path'] = mergedPath;
  ext['path'] = mergedPath;
  map['extern'] = ext;
  return map;
}

Map<String, dynamic> _normalizeStoredCreatorMap(Map<String, dynamic> creator) {
  final map = Map<String, dynamic>.from(creator);
  final avatar = Map<String, dynamic>.from(map['avatar'] as Map? ?? const {});
  if (avatar.isNotEmpty) {
    map['avatar'] = _normalizeStoredImageMap(avatar);
  }
  return map;
}

Future<void> _markTaskCompleted(String taskKey) async {
  const repository = DownloadTaskRepository();
  // 先排空在途的 checkpoint 写，再落完成态，防止旧写覆盖。
  await repository.flushTaskWrites(taskKey);
  final task = await repository.findByTaskKey(taskKey);
  if (task == null) return;
  final payload = repository.readPayload(task);
  task
    ..isCompleted = true
    ..isDownloading = false
    ..status = t.download.notificationCompleteTitle;
  if (payload != null) {
    task.taskInfo = payload.copyWith(
      stateCode: 'completed',
      phaseCode: 'completed',
    );
  }
  await database.downloadTasks.put(task);
}
