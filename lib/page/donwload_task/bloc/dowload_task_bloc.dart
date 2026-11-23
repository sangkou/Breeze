import 'dart:async';

import 'package:bloc/bloc.dart';

import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:zephyr/main.dart';
import 'package:zephyr/object_box/model.dart';
import 'package:zephyr/service/download/download_queue_manager.dart';
import 'package:zephyr/service/download/download_task_repository.dart';

part 'dowload_task_bloc.freezed.dart';
part 'dowload_task_event.dart';
part 'dowload_task_state.dart';

class DowloadTaskBloc extends Bloc<DowloadTaskEvent, DowloadTaskState> {
  StreamSubscription? _watchSubscription;

  DowloadTaskBloc() : super(_Initial()) {
    on<DowloadTaskEvent>(_onEvent);
  }

  void _onEvent(DowloadTaskEvent event, Emitter<DowloadTaskState> emit) {
    event.when(
      started: () => _watchTasks(),
      tasksUpdated: (tasks) => _handleTasksUpdated(tasks, emit),
      taskDeleted: (taskId) => unawaited(_deleteTask(taskId)),
      cancelCurrentTask: () => _cancelCurrentTask(emit),
      clearCompleted: () => unawaited(_clearCompletedTasks()),
    );
  }

  void _watchTasks() {
    _watchSubscription = database.downloadTasks.watchIncomplete().listen((
      tasks,
    ) {
      if (isClosed) return;
      add(DowloadTaskEvent.tasksUpdated(tasks));
    });
  }

  void _handleTasksUpdated(
    List<DownloadTask> tasks,
    Emitter<DowloadTaskState> emit,
  ) {
    emit(DowloadTaskState.loaded(tasks: tasks, pendingCount: tasks.length));
  }

  Future<void> _deleteTask(int taskId) async {
    final task = await database.downloadTasks.getById(taskId);
    if (task == null) return;
    String? taskKey;
    try {
      taskKey = task.taskInfo?.taskKey;
    } catch (e, st) {
      logger.e(e, stackTrace: st);
      taskKey = null;
    }
    // 先排空在途后台写再删，防止旧写复活已删除的任务。
    if (taskKey != null) {
      await const DownloadTaskRepository().flushTaskWrites(taskKey);
    }
    await database.downloadTasks.removeById(taskId);
  }

  void _cancelCurrentTask(Emitter<DowloadTaskState> emit) {
    DownloadQueueManager.instance.cancelCurrentTask();
  }

  Future<void> _clearCompletedTasks() async {
    final completedTasks = await database.downloadTasks.listCompleted();
    if (completedTasks.isEmpty) return;
    await database.downloadTasks.removeByIds(
      completedTasks.map((task) => task.id).toList(),
    );
  }

  @override
  Future<void> close() {
    _watchSubscription?.cancel();
    return super.close();
  }
}
