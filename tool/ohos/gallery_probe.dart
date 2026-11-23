import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:zephyr/util/ohos/file_bridge.dart';
import 'package:zephyr/util/ohos/platform_plugins.dart';

/// 验证 OHOS 相册保存通道：写入一张 1x1 PNG，然后调用系统保存对话框。
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  installOhosPlatformPlugins();
  runApp(const _GalleryProbeApp());
}

class _GalleryProbeApp extends StatelessWidget {
  const _GalleryProbeApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: const _GalleryProbePage(),
    );
  }
}

class _GalleryProbePage extends StatefulWidget {
  const _GalleryProbePage();

  @override
  State<_GalleryProbePage> createState() => _GalleryProbePageState();
}

class _GalleryProbePageState extends State<_GalleryProbePage> {
  final List<String> _lines = <String>[];
  static const _pngBase64 =
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
      '+A8AAQUBAScY42YAAAAASUVORK5CYII=';

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    try {
      final dir = await getTemporaryDirectory();
      final file = File(p.join(dir.path, 'breeze_probe.png'));
      await file.writeAsBytes(base64Decode(_pngBase64));
      setState(() => _lines.add('file: ${file.path}'));
      await saveImageToOhosGallery(file.path);
      setState(() => _lines.add('saveImage: success'));
    } catch (error) {
      setState(() => _lines.add('saveImage failed: $error'));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('OHOS gallery probe')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [for (final line in _lines) Text(line)],
      ),
    );
  }
}
