import 'package:flutter/foundation.dart';
import '../../core/constants.dart';
import '../../domain/models/task_item.dart';
import 'planning_engine.dart';
import 'task_sync_coordinator.dart';

class TaskRecoveryResult {
  final int successCount;
  final int partialSyncCount;
  final int skippedConflictCount;
  final int skippedDeadlineCount;
  final int databaseUpdateFailedCount;
  final int databaseReadFailedCount;
  final int syncFailedCount;

  const TaskRecoveryResult({
    this.successCount = 0,
    this.partialSyncCount = 0,
    this.skippedConflictCount = 0,
    this.skippedDeadlineCount = 0,
    this.databaseUpdateFailedCount = 0,
    this.databaseReadFailedCount = 0,
    this.syncFailedCount = 0,
  });

  bool get hasAnyFailure =>
      databaseUpdateFailedCount > 0 ||
      databaseReadFailedCount > 0 ||
      syncFailedCount > 0;
}

class RecoveryEngine {
  static String formatDateToKey(DateTime date) {
    return "${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}";
  }

  static Future<TaskRecoveryResult> recoverMissedTasks({
    required List<TaskItem> missedTasks,
    required DateTime currentDayDate,
    required DateTime currentWeekMonday,
    required Map<int, List<TaskItem>> activeTasks,
  }) async {
    int successCount = 0;
    int partialSyncCount = 0;
    int skippedConflictCount = 0;
    int skippedDeadlineCount = 0;
    int dbUpdateFailedCount = 0;
    int syncFailedCount = 0;

    final user = supabase.auth.currentUser;
    if (user == null) {
      return const TaskRecoveryResult(databaseReadFailedCount: 1);
    }

    final tomDate = currentDayDate.add(const Duration(days: 1));
    final tomDayIdx = (tomDate.weekday - 1) % 7;
    final targetTasks = activeTasks[tomDayIdx] ?? [];
    final tomWeekStart = tomDate.subtract(Duration(days: tomDate.weekday - 1));

    int currentHour = 10;

    for (var task in missedTasks) {
      DateTime targetStart =
          DateTime(tomDate.year, tomDate.month, tomDate.day, currentHour, 0);
      DateTime targetEnd =
          targetStart.add(Duration(minutes: task.durationMinutes));

      if (task.deadline != null && targetEnd.isAfter(task.deadline!)) {
        skippedDeadlineCount++;
        continue;
      }

      final candidateTask = TaskItem(
        id: task.id,
        userId: task.userId,
        title: task.title,
        category: task.category,
        taskMode: task.taskMode,
        dayIndex: tomDayIdx,
        scheduledDate: formatDateToKey(tomDate),
        weekStartDate: formatDateToKey(tomWeekStart),
        taskTime: "${currentHour.toString().padLeft(2, '0')}:00",
        durationMinutes: task.durationMinutes,
        priority: task.priority,
        deadline: task.deadline,
        reminderTime: task.reminderTime,
        isCompleted: false,
        version: task.version,
      );

      if (PlanningEngine.wouldConflictOnTargetDay(
          candidateTask, tomDate, targetTasks)) {
        skippedConflictCount++;
        continue;
      }

      final formattedTime = "${currentHour.toString().padLeft(2, '0')}:00";

      // Claude P1 Çözümü: Ham update yerine save_task_mutation RPC'si
      try {
        final res = await supabase.rpc(
          'save_task_mutation',
          params: {
            'p_task_id': task.id,
            'p_title': task.title,
            'p_category': task.category,
            'p_day_index': tomDayIdx,
            'p_scheduled_date': formatDateToKey(tomDate),
            'p_week_start_date': formatDateToKey(tomWeekStart),
            'p_task_time': formattedTime,
            'p_duration_minutes': task.durationMinutes,
            'p_priority': task.priority,
            'p_deadline': task.deadline?.toIso8601String(),
            'p_reminder_time': task.reminderTime,
            'p_is_completed': false,
            'p_expected_version': task.version,
          },
        );

        if (res is Map && res['success'] == true) {
          task.dayIndex = tomDayIdx;
          task.scheduledDate = formatDateToKey(tomDate);
          task.weekStartDate = formatDateToKey(tomWeekStart);
          task.taskTime = formattedTime;
          task.version = res['version'] ?? (task.version + 1);

          final syncRes = await TaskSyncCoordinator.coordinateTaskSync(
            task: task,
            targetDate: tomDate,
          );

          if (syncRes.isFullySynced) {
            successCount++;
          } else {
            partialSyncCount++;
          }
        } else {
          dbUpdateFailedCount++;
        }
      } catch (e) {
        debugPrint("Recovery RPC Hatası: $e");
        dbUpdateFailedCount++;
      }

      currentHour = (currentHour + (task.durationMinutes / 60).ceil() + 1);
      if (currentHour > 20) currentHour = 10;
    }

    return TaskRecoveryResult(
      successCount: successCount,
      partialSyncCount: partialSyncCount,
      skippedConflictCount: skippedConflictCount,
      skippedDeadlineCount: skippedDeadlineCount,
      databaseUpdateFailedCount: dbUpdateFailedCount,
      syncFailedCount: syncFailedCount,
    );
  }
}
