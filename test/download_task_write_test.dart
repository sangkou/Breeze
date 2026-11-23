import 'package:flutter_test/flutter_test.dart';
import 'package:zephyr/main.dart';
import 'package:zephyr/object_box/model.dart';
import 'package:zephyr/service/download/download_task_repository.dart';
import 'package:zephyr/service/download/models/download_task_json.dart';

import 'test_helper.dart';

DownloadTaskJson _payload({required int completed}) {
  return DownloadTaskJson(
    from: 'plugin-a',
    comicId: 'comic-1',
    comicName: '测试漫画',
    chapterRef: const DownloadChapterTaskRef(
      chapterId: 'chapter-1',
      logicalKey: 'logical-1',
      title: '第 1 话',
      order: 1,
    ),
    stateCode: 'running',
    phaseCode: 'downloadingChapter',
    completedImages: completed,
    totalImages: 3,
    imagePaths: List<String>.generate(completed, (i) => 'img/$i.jpg'),
  );
}

void main() {
  const repository = DownloadTaskRepository();

  setUp(TestDatabaseHelper.setUpTestDatabase);
  tearDown(TestDatabaseHelper.tearDownTestDatabase);

  test('高频后台写合并为最后一次 payload，只改状态的写不丢 payload', () async {
    final payload = _payload(completed: 1);
    final task = DownloadTask()
      ..comicId = payload.comicId
      ..comicName = payload.comicName
      ..isCompleted = false
      ..isDownloading = true
      ..status = 'running';
    final id = await repository.putPayload(task, payload);
    final taskKey = payload.taskKey;

    // 连续三次写：前两次带 payload，最后一次只改状态。合并后应保留最新
    // payload（completed=2）和最新状态，且不覆盖 isDownloading 等未传字段。
    await repository.putTaskWriteBackground(
      taskKey: taskKey,
      taskId: id,
      status: 'progress-1',
      payloadJson: downloadTaskJsonToJson(_payload(completed: 1)),
    );
    await repository.putTaskWriteBackground(
      taskKey: taskKey,
      taskId: id,
      status: 'progress-2',
      payloadJson: downloadTaskJsonToJson(_payload(completed: 2)),
    );
    await repository.putTaskWriteBackground(
      taskKey: taskKey,
      taskId: id,
      status: 'status-only',
    );
    await repository.flushTaskWrites(taskKey);

    final stored = (await database.downloadTasks.getById(id))!;
    expect(stored.status, 'status-only');
    expect(stored.isDownloading, isTrue);
    expect(stored.isCompleted, isFalse);

    final restored = repository.readPayload(stored)!;
    expect(restored.completedImages, 2);
    expect(restored.totalImages, 3);
    expect(restored.imagePaths, ['img/0.jpg', 'img/1.jpg']);
    expect(restored.taskKey, taskKey);

    // 章节任务只能靠 payload 里的 taskKey 命中；读库丢 payload 会让进度写
    // 全部静默 no-op（updateCheckpoint 直接 return）。
    final byKey = await repository.findByTaskKey(taskKey);
    expect(byKey?.id, id);
  });
}
