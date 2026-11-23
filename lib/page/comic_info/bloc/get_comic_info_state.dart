import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:zephyr/page/comic_info/json/normal/normal_comic_all_info.dart';

part 'get_comic_info_state.freezed.dart';

enum GetComicInfoStatus { initial, success, failure }

@freezed
abstract class GetComicInfoState with _$GetComicInfoState {
  const factory GetComicInfoState({
    @Default(GetComicInfoStatus.initial) GetComicInfoStatus status,
    NormalComicAllInfo? allInfo,
    // 用来存储漫画的原本的信息
    dynamic comicInfo,
    String? comicId,
    // 本地收藏状态与详情同一次 emit：首帧就要显示正确状态，
    // 不再由页面先渲染「未收藏」再异步查库跳变。
    @Default(false) bool localCollected,
    // 已读章节集合与详情一起返回，章节已读灰标首帧即正确。
    // 阅读历史摘要写入 StringSelectCubit（横幅/FAB 的唯一展示源）。
    @Default(<String>{}) Set<String> readChapterIds,
    @Default('') String result,
  }) = _GetComicInfoState;
}
