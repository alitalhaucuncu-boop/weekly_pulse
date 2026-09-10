import 'package:flutter/foundation.dart';
import '../core/constants.dart';
import '../domain/models/task_item.dart';
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
}

class RecoveryEngine {
  static String _formatDate(DateTime d) {
    return "${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}";
  }

  static Future<TaskRecoveryResult> recoverMissedTasks({
    required List<TaskItem> missedTasks,
    required DateTime currentDayDate,
    required DateTime currentWeekMonday,
    required Map<int, List<TaskItem>> activeTasks,
  }) async {
    final user = supabase.auth.currentUser;
    if (user == null) {
      return const TaskRecoveryResult(databaseReadFailedCount: 1);
    }

    int success = 0;
    int partialSync = 0;
    int skippedConflict = 0;
    int skippedDeadline = 0;
    int dbUpdateFail = 0;
    int dbReadFail = 0;
    int syncFail = 0;

    final tomorrowDate = currentDayDate.add(const Duration(days: 1));
    final tomorrowWeekStart =
        tomorrowDate.subtract(Duration(days: tomorrowDate.weekday - 1));
    final tomorrowDayIdx = tomorrowDate.weekday - 1;

    List<TaskItem> targetTasks = List.from(activeTasks[tomorrowDayIdx] ?? []);
    int currentHour = 10;

    for (var task in missedTasks) {
      DateTime candidateStart = DateTime(
        tomorrowDate.year,
        tomorrowDate.month,
        tomorrowDate.day,
        currentHour,
        0,
      );
      DateTime candidateEnd =
          candidateStart.add(Duration(minutes: task.durationMinutes));

      if (task.deadline != null && candidateEnd.isAfter(task.deadline!)) {
        skippedDeadline++;
        continue;
      }

      final candidateTask = TaskItem(
        id: task.id,
        userId: task.userId,
        title: task.title,
        category: task.category,
        dayIndex: tomorrowDayIdx,
        scheduledDate: _formatDate(tomorrowDate),
        weekStartDate: _formatDate(tomorrowWeekStart),
        taskMode: task.taskMode,
        taskTime: "${currentHour.toString().padLeft(2, '0')}:00",
        durationMinutes: task.durationMinutes,
        priority: task.priority,
        deadline: task.deadline,
        reminderTime: task.reminderTime,
        isCompleted: false,
        version: task.version,
      );

      final hasConflict = PlanningEngine.wouldConflictOnTargetDay(
        candidateTask,
        tomorrowDate,
        targetTasks,
      );

      if (hasConflict) {
        skippedConflict++;
        currentHour = (currentHour + (task.durationMinutes ~/ 60) + 1);
        if (currentHour > 20) currentHour = 10;
        continue;
      }

      // Veritabanındaki güncel versiyonu alarak çakışmayı önle
      int expectedVer = task.version;
      try {
        final currentDbRow = await supabase
            .from('weekly_tasks')
            .select('version')
            .eq('id', task.id)
            .eq('user_id', user.id)
            .maybeSingle();
        if (currentDbRow != null && currentDbRow['version'] != null) {
          expectedVer = currentDbRow['version'] as int;
        }
      } catch (e) {
        debugPrint("Recovery DB Read Hatası: $e");
        dbReadFail++;
        continue;
      }

      try {
        final dynamic res = await supabase.rpc(
          'save_task_mutation',
          params: {
            'p_task_id': task.id,
            'p_title': task.title,
            'p_category': task.category,
            'p_day_index': tomorrowDayIdx,
            'p_scheduled_date': _formatDate(tomorrowDate),
            'p_week_start_date': _formatDate(tomorrowWeekStart),
            'p_task_time': "${currentHour.toString().padLeft(2, '0')}:00",
            'p_duration_minutes': task.durationMinutes,
            'p_priority': task.priority,
            'p_deadline': task.deadline?.toIso8601String(),
            'p_reminder_time': task.reminderTime,
            'p_is_completed': false,
            'p_expected_version': expectedVer,
            'p_request_id':
                'recovery_${task.id}_${DateTime.now().millisecondsSinceEpoch}',
          },
        );

        if (res is Map && res['success'] == true) {
          task.dayIndex = tomorrowDayIdx;
          task.scheduledDate = _formatDate(tomorrowDate);
          task.weekStartDate = _formatDate(tomorrowWeekStart);
          task.taskTime = "${currentHour.toString().padLeft(2, '0')}:00";
          task.version = res['version'] ?? (expectedVer + 1);

          targetTasks.add(candidateTask);

          final syncRes = await TaskSyncCoordinator.coordinateTaskSync(
            task: task,
            targetDate: tomorrowDate,
          );

          if (syncRes.isFullySynced) {
            success++;
          } else {
            partialSync++;
          }

          currentHour = (currentHour + (task.durationMinutes ~/ 60) + 1);
          if (currentHour > 20) currentHour = 10;
        } else {
          dbUpdateFail++;
        }
      } catch (e) {
        debugPrint("Recovery RPC Hatası: $e");
        dbUpdateFail++;
      }
    }

    return TaskRecoveryResult(
      successCount: success,
      partialSyncCount: partialSync,
      skippedConflictCount: skippedConflict,
      skippedDeadlineCount: skippedDeadline,
      databaseUpdateFailedCount: dbUpdateFail,
      databaseReadFailedCount: dbReadFail,
      syncFailedCount: syncFail,
    );
  }
}
