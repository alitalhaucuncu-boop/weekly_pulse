import 'package:flutter/foundation.dart';
import '../../core/constants.dart';
import '../../domain/models/task_item.dart';
import 'planning_engine.dart';
import 'task_sync_coordinator.dart';

enum RecoveryOutcome {
  success,
  partialSync,
  skippedConflict,
  skippedDeadline,
  databaseUpdateFailed,
  databaseReadFailed,
  syncFailed,
}

class TaskRecoveryResult {
  final TaskItem task;
  final RecoveryOutcome outcome;
  final String? message;

  const TaskRecoveryResult({
    required this.task,
    required this.outcome,
    this.message,
  });

  bool get isSuccess => outcome == RecoveryOutcome.success;
  bool get isPartialSync => outcome == RecoveryOutcome.partialSync;
}

class BatchRecoveryResult {
  final List<TaskRecoveryResult> results;

  const BatchRecoveryResult({required this.results});

  int get successCount =>
      results.where((r) => r.outcome == RecoveryOutcome.success).length;
  int get partialSyncCount =>
      results.where((r) => r.outcome == RecoveryOutcome.partialSync).length;
  int get skippedConflictCount =>
      results.where((r) => r.outcome == RecoveryOutcome.skippedConflict).length;
  int get skippedDeadlineCount =>
      results.where((r) => r.outcome == RecoveryOutcome.skippedDeadline).length;
  int get databaseUpdateFailedCount => results
      .where((r) => r.outcome == RecoveryOutcome.databaseUpdateFailed)
      .length;
  int get databaseReadFailedCount => results
      .where((r) => r.outcome == RecoveryOutcome.databaseReadFailed)
      .length;
  int get syncFailedCount =>
      results.where((r) => r.outcome == RecoveryOutcome.syncFailed).length;
}

class RecoveryEngine {
  static String formatDateToKey(DateTime date) {
    return "${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}";
  }

  static Future<BatchRecoveryResult> recoverMissedTasks({
    required List<TaskItem> missedTasks,
    required DateTime currentDayDate,
    required DateTime currentWeekMonday,
    required Map<int, List<TaskItem>> activeTasks,
  }) async {
    final List<TaskRecoveryResult> outcomes = [];
    final user = supabase.auth.currentUser;

    if (user == null) {
      return const BatchRecoveryResult(results: []);
    }

    final Map<String, List<TaskItem>> workingSchedule = {};

    for (int i = 0; i < 7; i++) {
      final dateKey = formatDateToKey(currentWeekMonday.add(Duration(days: i)));
      workingSchedule[dateKey] = List<TaskItem>.from(activeTasks[i] ?? []);
    }

    final List<(int hour, int minute)> candidateSlots = [
      (9, 0),
      (9, 30),
      (10, 0),
      (10, 30),
      (11, 0),
      (11, 30),
      (13, 0),
      (13, 30),
      (14, 0),
      (14, 30),
      (15, 0),
      (15, 30),
      (16, 0),
      (16, 30),
      (17, 0),
      (17, 30),
      (18, 0),
      (18, 30),
      (19, 0),
      (19, 30),
      (20, 0)
    ];

    for (var task in missedTasks) {
      DateTime? chosenDate;
      int chosenDayIndex = -1;
      String? chosenTime;
      bool readFailureOccurred = false;

      for (int offset = 1; offset <= 3; offset++) {
        final candidateDate = currentDayDate.add(Duration(days: offset));
        final candidateWeekMonday =
            candidateDate.subtract(Duration(days: candidateDate.weekday - 1));
        final candidateDayIndex = candidateDate.weekday - 1;
        final candidateDateKey = formatDateToKey(candidateDate);

        List<TaskItem> dayTasks = [];

        if (workingSchedule.containsKey(candidateDateKey)) {
          dayTasks = workingSchedule[candidateDateKey]!;
        } else {
          try {
            final response = await supabase
                .from('weekly_tasks')
                .select()
                .eq('user_id', user.id)
                .eq('scheduled_date', candidateDateKey)
                .order('task_time', ascending: true);

            dayTasks = (response as List)
                .map((row) => TaskItem.fromJson(row))
                .toList();
            workingSchedule[candidateDateKey] = dayTasks;
          } catch (e) {
            debugPrint("Cross-week Görev Okuma Hatası ($candidateDateKey): $e");
            readFailureOccurred = true;
            continue;
          }
        }

        final origStart = DateTime(
          candidateDate.year,
          candidateDate.month,
          candidateDate.day,
          task.startDateTime.hour,
          task.startDateTime.minute,
        );
        final origEnd = origStart.add(Duration(minutes: task.durationMinutes));

        bool origDeadlineOk =
            (task.deadline == null || !origEnd.isAfter(task.deadline!));
        bool origConflict = PlanningEngine.wouldConflictOnTargetDay(
            task, candidateDate, dayTasks);

        if (origDeadlineOk && !origConflict) {
          chosenDate = candidateDate;
          chosenDayIndex = candidateDayIndex;
          chosenTime = task.taskTime;
          break;
        }

        for (var slot in candidateSlots) {
          final slotStart = DateTime(candidateDate.year, candidateDate.month,
              candidateDate.day, slot.$1, slot.$2);
          final slotEnd =
              slotStart.add(Duration(minutes: task.durationMinutes));

          if (task.deadline != null && slotEnd.isAfter(task.deadline!))
            continue;

          final candidateTaskClone = TaskItem(
            id: task.id,
            userId: task.userId,
            title: task.title,
            category: task.category,
            dayIndex: candidateDayIndex,
            scheduledDate: candidateDateKey,
            weekStartDate: formatDateToKey(candidateWeekMonday),
            taskTime:
                "${slot.$1.toString().padLeft(2, '0')}:${slot.$2.toString().padLeft(2, '0')}",
            durationMinutes: task.durationMinutes,
            priority: task.priority,
            deadline: task.deadline,
          );

          if (!PlanningEngine.wouldConflictOnTargetDay(
              candidateTaskClone, candidateDate, dayTasks)) {
            chosenDate = candidateDate;
            chosenDayIndex = candidateDayIndex;
            chosenTime = candidateTaskClone.taskTime;
            break;
          }
        }

        if (chosenDate != null) break;
      }

      if (chosenDate == null) {
        if (readFailureOccurred) {
          outcomes.add(TaskRecoveryResult(
            task: task,
            outcome: RecoveryOutcome.databaseReadFailed,
            message: 'Hedef günlerin planları okunamadı.',
          ));
        } else {
          outcomes.add(TaskRecoveryResult(
            task: task,
            outcome: RecoveryOutcome.skippedConflict,
            message: 'Gelecek 3 gün içinde uygun boş zaman dilimi bulunamadı.',
          ));
        }
        continue;
      }

      final derivedWeekStart =
          chosenDate.subtract(Duration(days: chosenDate.weekday - 1));
      final formattedDate = formatDateToKey(chosenDate);
      final formattedWeekStart = formatDateToKey(derivedWeekStart);

      try {
        final updateRes = await supabase
            .from('weekly_tasks')
            .update({
              'day_index': chosenDayIndex,
              'scheduled_date': formattedDate,
              'week_start_date': formattedWeekStart,
              'task_time': chosenTime,
            })
            .eq('id', task.id)
            .eq('user_id', user.id)
            .select()
            .maybeSingle();

        if (updateRes == null) {
          outcomes.add(TaskRecoveryResult(
            task: task,
            outcome: RecoveryOutcome.databaseUpdateFailed,
            message: 'Veritabanı satırı güncellenemedi.',
          ));
          continue;
        }

        task.dayIndex = chosenDayIndex;
        task.scheduledDate = formattedDate;
        task.weekStartDate = formattedWeekStart;
        task.taskTime = chosenTime!;

        // Idempotent Upsert: Listedeki eski referansı temizleyip yenisini ekle
        workingSchedule
            .putIfAbsent(formattedDate, () => [])
            .removeWhere((t) => t.id == task.id);
        workingSchedule[formattedDate]!.add(task);

        final syncResult = await TaskSyncCoordinator.coordinateTaskSync(
          task: task,
          targetDate: chosenDate,
        );

        if (syncResult.isFullySynced) {
          outcomes.add(TaskRecoveryResult(
            task: task,
            outcome: RecoveryOutcome.success,
            message:
                'Görev ${fullWeekDays[chosenDayIndex]} $chosenTime saatine taşındı.',
          ));
        } else {
          outcomes.add(TaskRecoveryResult(
            task: task,
            outcome: RecoveryOutcome.partialSync,
            message: syncResult.effectiveUserMessage ??
                'Taşındı fakat tam eşitlenemedi.',
          ));
        }
      } catch (e) {
        debugPrint("Kurtarma Taşıma Hatası: $e");
        outcomes.add(TaskRecoveryResult(
          task: task,
          outcome: RecoveryOutcome.databaseUpdateFailed,
          message: 'Veritabanı bağlantı hatası.',
        ));
      }
    }

    return BatchRecoveryResult(results: outcomes);
  }
}
