import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:zephyr/config/global/global_setting.dart';
import 'package:zephyr/i18n/strings.g.dart';
import 'package:zephyr/main.dart';
import 'package:zephyr/page/setting/global/appearance_setting_page.dart';

class _TestGlobalSettingCubit extends GlobalSettingCubit {
  @override
  void updateState(GlobalSettingState Function(GlobalSettingState) updates) {
    emit(updates(state));
  }
}

void main() {
  test('滚动条显示默认值按平台区分', () {
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(const GlobalSettingState().effectiveShowScrollbar, isFalse);
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    expect(const GlobalSettingState().effectiveShowScrollbar, isFalse);

    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    expect(const GlobalSettingState().effectiveShowScrollbar, isTrue);
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    expect(const GlobalSettingState().effectiveShowScrollbar, isTrue);
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    expect(const GlobalSettingState().effectiveShowScrollbar, isTrue);

    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(
      const GlobalSettingState(showScrollbar: false).effectiveShowScrollbar,
      isFalse,
    );
    expect(
      const GlobalSettingState(showScrollbar: true).effectiveShowScrollbar,
      isTrue,
    );
  });

  test('旧配置缺少滚动条字段时回退到平台默认', () {
    final json = const GlobalSettingState(showScrollbar: true).toJson()
      ..remove('showScrollbar')
      ..remove('alwaysShowScrollbar');

    final restored = GlobalSettingState.fromJson(json);
    expect(restored.showScrollbar, isNull);
    expect(restored.alwaysShowScrollbar, isFalse);
  });

  testWidgets('AppScrollBehavior 按开关决定是否包 Scrollbar', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        scrollBehavior: const AppScrollBehavior(showScrollbar: false),
        home: Scaffold(
          body: ListView(children: const [SizedBox(height: 2000)]),
        ),
      ),
    );
    expect(find.byType(Scrollbar), findsNothing);

    await tester.pumpWidget(
      MaterialApp(
        scrollBehavior: const AppScrollBehavior(
          showScrollbar: true,
          alwaysVisible: true,
        ),
        home: Scaffold(
          body: ListView(children: const [SizedBox(height: 2000)]),
        ),
      ),
    );
    final scrollbar = tester.widget<Scrollbar>(find.byType(Scrollbar));
    expect(scrollbar.thumbVisibility, isTrue);
    expect(scrollbar.thickness, 6);
  });

  testWidgets('外观设置页可切换滚动条显示与常驻', (tester) async {
    await LocaleSettings.setLocale(AppLocale.zhCn);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    final cubit = _TestGlobalSettingCubit();
    await tester.pumpWidget(
      BlocProvider<GlobalSettingCubit>.value(
        value: cubit,
        child: const MaterialApp(home: AppearanceSettingPage()),
      ),
    );

    await tester.scrollUntilVisible(
      find.text(t.settings.showScrollbar),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    final showTile = find.widgetWithText(
      SwitchListTile,
      t.settings.showScrollbar,
    );
    expect(tester.widget<SwitchListTile>(showTile).value, isFalse);
    expect(find.text(t.settings.alwaysShowScrollbar), findsNothing);

    await tester.tap(find.text(t.settings.showScrollbar));
    await tester.pump();
    expect(cubit.state.showScrollbar, isTrue);
    await tester.pump();

    await tester.scrollUntilVisible(
      find.text(t.settings.alwaysShowScrollbar),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text(t.settings.alwaysShowScrollbar));
    await tester.pump();
    expect(cubit.state.alwaysShowScrollbar, isTrue);
  });
}
