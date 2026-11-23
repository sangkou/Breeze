import 'package:bloc/bloc.dart';
import 'package:bloc_concurrency/bloc_concurrency.dart';
import 'package:zephyr/cubit/string_select.dart';
import 'package:zephyr/main.dart';
import 'package:zephyr/object_box/model.dart';
import 'package:zephyr/page/comic_info/comic_info.dart';
import 'package:zephyr/page/comic_info/json/normal/normal_comic_all_info.dart'
    as normal;
import 'package:zephyr/service/download/download_chapter_isolate.dart';
import 'package:zephyr/service/reader/comic_read_chapter_repository.dart';
import 'package:zephyr/type/enum.dart';
import 'package:zephyr/util/async/worker_pool.dart';
import 'package:zephyr/util/error/error_filter.dart';

export 'package:zephyr/page/comic_info/bloc/get_comic_info_event.dart';
export 'package:zephyr/page/comic_info/bloc/get_comic_info_state.dart';

class GetComicInfoBloc extends Bloc<GetComicInfoEvent, GetComicInfoState> {
  GetComicInfoBloc(this._stringSelectCubit) : super(const GetComicInfoState()) {
    // 编辑返回后的刷新必须生效；最新一次请求覆盖旧结果。
    on<GetComicInfoEvent>(_fetchComicInfo, transformer: restartable());
  }

  /// 阅读历史摘要的展示源；成功 emit 前写入，页面首帧即可显示。
  final StringSelectCubit _stringSelectCubit;

  Future<void> _fetchComicInfo(
    GetComicInfoEvent event,
    Emitter<GetComicInfoState> emit,
  ) async {
    try {
      emit(state.copyWith(status: GetComicInfoStatus.initial));

      // 收藏状态、阅读历史、已读章节都是本地库读，与详情并行：
      // 等详情返回时已就绪，首帧不再先显示「未收藏/无历史」再跳变。
      final inputComicId = event.comicId;
      final collectedForInputId = _readLocalCollected(event.from, inputComicId);
      final historyForInputId = _readHistory(event.from, inputComicId);
      final readIdsForInputId = _readReadChapterIds(event.from, inputComicId);

      late normal.NormalComicAllInfo normalComicInfo;
      late String resolvedComicId;
      dynamic comicInfo;
      normal.NormalComicAllInfo? downloadedInfo;

      if (event.type == ComicEntryType.download) {
        // 记录读取、detailJson 解析与目录排序都在后台 isolate 内完成；
        // 任务对象在 UI isolate 构造（后台 isolate 里没有全局 database）。
        final task = DownloadComicInfoTask(
          handle: database.db.handle,
          downloadKey: '${event.from}:$inputComicId',
        );
        final downloaded = await runInIsolate(
          readDownloadedComicInfoInWorker,
          task,
        );
        comicInfo = downloaded.record;
        downloadedInfo = downloaded.info;
      }

      if (comicInfo == null) {
        final pluginResult = await getComicDetailByPlugin(
          inputComicId,
          event.from,
          extern: event.extern,
        );
        comicInfo = pluginResult.source;
        normalComicInfo = pluginResult.normalInfo;
        resolvedComicId = pluginResult.comicId;
      } else {
        final download = comicInfo as UnifiedComicDownload;
        normalComicInfo = downloadedInfo!;
        resolvedComicId = download.comicId;
      }

      // 插件可能改写 comicId；只有解析结果与入参一致才能复用预读结果。
      final reusePrefetch = resolvedComicId == inputComicId;
      final localCollected = reusePrefetch
          ? await collectedForInputId
          : await _readLocalCollected(event.from, resolvedComicId);
      final history = reusePrefetch
          ? await historyForInputId
          : await _readHistory(event.from, resolvedComicId);
      final readChapterIds = reusePrefetch
          ? await readIdsForInputId
          : await _readReadChapterIds(event.from, resolvedComicId);
      final historySummary = _buildHistorySummary(history, normalComicInfo.eps);

      // 先刷新历史展示源再 emit success：横幅与 FAB 首帧即可正确。
      // 请求被刷新/关闭取代时跳过，避免旧结果覆盖新光标。
      if (!emit.isDone) {
        _stringSelectCubit.setDate(historySummary);
      }
      emit(
        state.copyWith(
          status: GetComicInfoStatus.success,
          allInfo: normalComicInfo,
          comicInfo: comicInfo,
          comicId: resolvedComicId,
          localCollected: localCollected,
          readChapterIds: readChapterIds,
        ),
      );
    } catch (e, s) {
      logger.e(e, stackTrace: s);
      emit(
        state.copyWith(
          status: GetComicInfoStatus.failure,
          result: normalizeSearchErrorMessage(e),
        ),
      );
    }
  }

  /// 收藏状态只是页面辅助信息：读库失败时按未收藏处理，不拖垮详情页。
  Future<bool> _readLocalCollected(String from, String comicId) async {
    try {
      return await isLocalComicCollected(from: from, comicId: comicId);
    } catch (e, s) {
      logger.e(e, stackTrace: s);
      return false;
    }
  }

  /// 阅读历史读库失败按无历史处理，不影响详情展示。
  Future<UnifiedComicHistory?> _readHistory(String from, String comicId) async {
    try {
      final history = await database.histories.getByKey(
        '${from.trim()}:$comicId',
      );
      if (history == null || history.deleted) return null;
      return history;
    } catch (e, s) {
      logger.e(e, stackTrace: s);
      return null;
    }
  }

  /// 已读章节集合同样只是辅助信息，失败按空集合处理。
  Future<Set<String>> _readReadChapterIds(String from, String comicId) async {
    try {
      return await ComicReadChapterRepository.instance.readChapterIds(
        source: from,
        comicId: comicId,
      );
    } catch (e, s) {
      logger.e(e, stackTrace: s);
      return const <String>{};
    }
  }

  /// 「继续阅读」横幅文案：章节顺序前缀 + 章节标题 + 页码 + 本地时间。
  String _buildHistorySummary(
    UnifiedComicHistory? history,
    List<normal.Ep> chapters,
  ) {
    if (history == null) return '';
    final chapterTitle = history.chapterTitle.isNotEmpty
        ? history.chapterTitle
        : '';
    int? order;
    if (history.chapterId.isNotEmpty) {
      final matched = chapters.cast<normal.Ep?>().firstWhere(
        (ep) => ep?.id == history.chapterId,
        orElse: () => null,
      );
      order = matched?.order;
    }
    final prefix = (order != null && order > 0) ? '$order-' : '';
    return '$prefix$chapterTitle / '
        '${history.pageIndex - 1} / '
        '${history.lastReadAt.toLocal().toString().substring(0, 19)}';
  }
}
