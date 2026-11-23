import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:zephyr/service/reader/reader_volume_service.dart';

/// 验证 OHOS 音量键通道。
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _VolumeProbeApp());
}

class _VolumeProbeApp extends StatelessWidget {
  const _VolumeProbeApp();

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: _VolumeProbePage(),
    );
  }
}

class _VolumeProbePage extends StatefulWidget {
  const _VolumeProbePage();

  @override
  State<_VolumeProbePage> createState() => _VolumeProbePageState();
}

class _VolumeProbePageState extends State<_VolumeProbePage> {
  final List<String> _events = <String>[];
  StreamSubscription<String>? _subscription;

  @override
  void initState() {
    super.initState();
    _subscription = ReaderVolumeService.instance.volumeEvents.listen((event) {
      setState(() => _events.insert(0, event));
    });
    ReaderVolumeService.instance.enableInterception();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    ReaderVolumeService.instance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('OHOS volume key probe')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('按下音量上/下键，事件会显示在这里。'),
            const SizedBox(height: 16),
            Text('count: ${_events.length}'),
            const SizedBox(height: 8),
            for (final event in _events.take(10)) Text(event),
          ],
        ),
      ),
    );
  }
}
