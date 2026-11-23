import 'package:material_ui/material_ui.dart';
import 'package:zephyr/util/ohos/file_bridge.dart';
import 'package:zephyr/util/ohos/notification.dart';

/// 验证 OHOS 系统通知发布。
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _NotificationProbeApp());
}

class _NotificationProbeApp extends StatelessWidget {
  const _NotificationProbeApp();

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: _NotificationProbePage(),
    );
  }
}

class _NotificationProbePage extends StatefulWidget {
  const _NotificationProbePage();

  @override
  State<_NotificationProbePage> createState() => _NotificationProbePageState();
}

class _NotificationProbePageState extends State<_NotificationProbePage> {
  String _status = '请求通知权限并发布…';

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    final granted = await requestOhosNotificationPermission();
    if (!granted) {
      setState(() => _status = '通知权限未开启');
      return;
    }
    final published = await publishOhosNotification(
      id: 20261119,
      title: 'Breeze 通知测试',
      body: '如果你看到这条通知，OHOS 系统通知发布已生效。',
    );
    setState(() => _status = published ? '通知已发布，请下拉通知中心查看' : '系统未接受通知');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('OHOS notification probe')),
      body: Padding(padding: const EdgeInsets.all(16), child: Text(_status)),
    );
  }
}
