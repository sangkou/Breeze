import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:zephyr/config/global/global_setting.dart';
import 'package:zephyr/i18n/strings.g.dart';
import 'package:zephyr/page/comic_info/json/normal/normal_comic_all_info.dart';
import 'package:zephyr/page/comic_info/widgets/comic_operation.dart';
import 'package:zephyr/page/setting/global/comic_detail_setting_page.dart';

class _TestGlobalSettingCubit extends GlobalSettingCubit {
  @override
  void updateState(GlobalSettingState Function(GlobalSettingState) updates) {
    emit(updates(state));
  }

  void setComicDetail(ComicDetailSettingState value) {
    emit(state.copyWith(comicDetailSetting: value));
  }
}

void main() {
  testWidgets('漫画详情页设置页四个按钮开关独立生效', (tester) async {
    await LocaleSettings.setLocale(AppLocale.zhCn);
    final cubit = _TestGlobalSettingCubit();
    await tester.pumpWidget(
      BlocProvider<GlobalSettingCubit>.value(
        value: cubit,
        child: const MaterialApp(home: ComicDetailSettingPage()),
      ),
    );

    await tester.tap(find.text(t.settings.comicDetailShowLike));
    await tester.pump();
    expect(cubit.state.comicDetailSetting.showLikeAction, isFalse);
    expect(cubit.state.comicDetailSetting.showCommentAction, isTrue);
    expect(cubit.state.comicDetailSetting.showLocalCollectAction, isTrue);
    expect(cubit.state.comicDetailSetting.showCloudCollectAction, isTrue);

    await tester.tap(find.text(t.settings.comicDetailShowLocalCollect));
    await tester.pump();
    expect(cubit.state.comicDetailSetting.showLikeAction, isFalse);
    expect(cubit.state.comicDetailSetting.showLocalCollectAction, isFalse);
    expect(cubit.state.comicDetailSetting.showCloudCollectAction, isTrue);
  });

  testWidgets('关闭开关后详情页对应功能按钮隐藏且互不影响', (tester) async {
    await LocaleSettings.setLocale(AppLocale.zhCn);
    final cubit = _TestGlobalSettingCubit();
    final info = NormalComicAllInfo(
      comicInfo: const ComicInfo(
        id: 'c1',
        title: '测试漫画',
        titleMeta: [],
        description: '',
        cover: ComicImage(id: '', url: '', name: ''),
        metadata: [],
      ),
      eps: const [],
      recommend: const [],
      totalLikes: 7,
      totalComments: 3,
      allowLike: true,
      allowComments: true,
    );

    await tester.pumpWidget(
      BlocProvider<GlobalSettingCubit>.value(
        value: cubit,
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ComicOperationWidget(
                normalInfo: info,
                from: 'src',
                comicInfo: const <String, dynamic>{},
                initialCollected: false,
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text(t.comicInfo.likes(count: 7)), findsOneWidget);
    expect(find.text(t.comicInfo.comments(count: 3)), findsOneWidget);
    expect(find.text(t.comicInfo.collect), findsOneWidget);
    expect(find.text(t.comicInfo.cloudCollect), findsOneWidget);

    cubit.setComicDetail(
      const ComicDetailSettingState(
        showLikeAction: false,
        showCloudCollectAction: false,
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text(t.comicInfo.likes(count: 7)), findsNothing);
    expect(find.text(t.comicInfo.cloudCollect), findsNothing);
    expect(find.text(t.comicInfo.comments(count: 3)), findsOneWidget);
    expect(find.text(t.comicInfo.collect), findsOneWidget);

    cubit.setComicDetail(
      const ComicDetailSettingState(
        showLikeAction: false,
        showCommentAction: false,
        showLocalCollectAction: false,
        showCloudCollectAction: false,
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text(t.comicInfo.likes(count: 7)), findsNothing);
    expect(find.text(t.comicInfo.comments(count: 3)), findsNothing);
    expect(find.text(t.comicInfo.collect), findsNothing);
    expect(find.text(t.comicInfo.cloudCollect), findsNothing);
  });
}
