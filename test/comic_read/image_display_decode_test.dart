import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:zephyr/config/global/global_setting.dart';
import 'package:zephyr/cubit/comic_read_preference_cubit.dart';
import 'package:zephyr/page/comic_read/cubit/image_size_cubit.dart';
import 'package:zephyr/page/comic_read/cubit/reader_cubit.dart';
import 'package:zephyr/page/comic_read/widgets/image/image_display.dart';

/// 1x1 透明 PNG。
final Uint8List _onePixelPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk'
  'YPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

void main() {
  testWidgets('高 DPI 下按屏幕物理像素解码（cacheWidth = 逻辑宽度 × dpr）', (tester) async {
    tester.view.devicePixelRatio = 3.0;
    tester.view.physicalSize = const Size(1200, 2400);
    addTearDown(tester.view.reset);

    final tempDir = Directory.systemTemp.createTempSync('image_display_');
    addTearDown(() {
      try {
        tempDir.deleteSync(recursive: true);
      } on FileSystemException {
        // 图片异步读取可能仍持有句柄，临时目录交给系统清理。
      }
    });
    final imageFile = File('${tempDir.path}/page.png')
      ..writeAsBytesSync(_onePixelPng);

    final globalCubit = GlobalSettingCubit();
    final readerCubit = ReaderCubit();
    final sizeCubit = ImageSizeCubit.create(
      defaultWidth: 400,
      count: 1,
      sourceTag: 'test',
      pageKeys: const ['page_0'],
      chapterOrder: 0,
      persistedCache: const {},
    );

    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider.value(value: globalCubit),
          BlocProvider.value(value: ComicReadPreferenceCubit()),
          BlocProvider.value(value: readerCubit),
          BlocProvider.value(value: sizeCubit),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              child: ImageDisplay(
                imagePath: imageFile.path,
                isColumn: true,
                pageSlotIndex: 0,
                sizeCacheIndex: 0,
              ),
            ),
          ),
        ),
      ),
    );

    final image = tester.widget<Image>(find.byType(Image));
    final provider = image.image;
    expect(provider, isA<ResizeImage>());
    // 逻辑宽度 400 × dpr 3；若直接传逻辑宽度，高 DPI 下会按 400 物理像素解码而发虚。
    expect((provider as ResizeImage).width, 1200);
  });
}
