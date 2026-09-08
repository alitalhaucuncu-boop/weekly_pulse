import 'package:flutter/foundation.dart';
import '../../core/constants.dart';
import '../../domain/models/task_item.dart';
import '../../data/notification_service.dart';
import '../../data/calendar_service.dart';

class TaskSyncResult {
  final bool isFullySynced;
  final String? effectiveUserMessage;
  final bool notificationSuccess;
  final bool calendarSuccess;

  const TaskSyncResult({
    required this.isFullySynced,
    this.effectiveUserMessage,
    required this.notificationSuccess,
    required this.calendarSuccess,
  });
}

class TaskSyncCoordinator {
  static final TaskSyncCoordinator instance = TaskSyncCoordinator._internal();
  TaskSyncCoordinator._internal();

  static Future<TaskSyncResult> coordinateTaskSync({
    required TaskItem task,
    required DateTime targetDate,
  }) async {
    bool notifSuccess = false;
    bool calSuccess = false;
    String? notifError;
    String? calError;

    // 1. Bildirim Planlama & ID Atama (P0-01)
    final int resolvedNotifId =
        NotificationService.resolveNotificationId(task: task);
    task.notificationId = resolvedNotifId;

    if (!task.isCompleted) {
      try {
        final dynamic scheduleStatus =
            await NotificationService.scheduleTaskNotification(
          task: task,
          targetDate: targetDate,
        );

        final String statusStr = scheduleStatus.toString().toLowerCase();
        if (statusStr.contains('scheduled') ||
            scheduleStatus == true ||
            statusStr.contains('skippedpast')) {
          notifSuccess = true;
        } else {
          notifError = 'Bildirim kurulamadı ($scheduleStatus).';
        }
      } catch (e) {
        debugPrint("Senkronizasyon Bildirim Hatası: $e");
        notifError = e.toString();
      }
    } else {
      try {
        await NotificationService.cancelNotification(resolvedNotifId);
        notifSuccess = true;
      } catch (_) {}
    }

    // 2. Takvim Entegrasyonu (CalendarService ile dinamik dispatch)
    try {
      final calId = await CalendarService.getDefaultCalendarId();
      if (calId != null) {
        task.calendarId = calId;
        final dynamic service = CalendarService;

        if (task.calendarEventId == null) {
          dynamic newEventId;
          try {
            newEventId = await service.createEvent(
              calendarId: calId,
              task: task,
              targetDate: targetDate,
            );
          } catch (_) {
            try {
              newEventId = await service.createTaskEvent(
                calendarId: calId,
                task: task,
                targetDate: targetDate,
              );
            } catch (_) {
              newEventId = await service.insertEvent(
                calendarId: calId,
                task: task,
                targetDate: targetDate,
              );
            }
          }

          if (newEventId != null) {
            task.calendarEventId = newEventId.toString();
            calSuccess = true;
          } else {
            calError = 'Takvim etkinliği oluşturulamadı.';
          }
        } else {
          dynamic updated;
          try {
            updated = await service.updateEvent(
              calendarId: calId,
              eventId: task.calendarEventId!,
              task: task,
              targetDate: targetDate,
            );
          } catch (_) {
            try {
              updated = await service.updateTaskEvent(
                calendarId: calId,
                eventId: task.calendarEventId!,
                task: task,
                targetDate: targetDate,
              );
            } catch (_) {
              updated = await service.modifyEvent(
                calendarId: calId,
                eventId: task.calendarEventId!,
                task: task,
                targetDate: targetDate,
              );
            }
          }

          calSuccess = (updated == true || updated != null);
          if (!calSuccess) {
            calError = 'Takvim etkinliği güncellenemedi.';
          }
        }
      } else {
        calError = 'Varsayılan takvim bulunamadı.';
      }
    } catch (e) {
      debugPrint("Senkronizasyon Takvim Hatası: $e");
      calError = e.toString();
    }

    // 3. Metadata'yı Veritabanına Kalıcı Yazma (P0-01)
    final bool isAllSynced = notifSuccess && calSuccess;
    final String syncStatus = isAllSynced
        ? 'synced'
        : (notifSuccess || calSuccess ? 'partial' : 'failed');

    task.syncStatus = syncStatus;

    try {
      final user = supabase.auth.currentUser;
      if (user != null && task.id.isNotEmpty) {
        await supabase
            .from('weekly_tasks')
            .update({
              'notification_id': task.notificationId,
              'calendar_id': task.calendarId,
              'calendar_event_id': task.calendarEventId,
              'sync_status': syncStatus,
              'last_synced_at': DateTime.now().toUtc().toIso8601String(),
            })
            .eq('id', task.id)
            .eq('user_id', user.id);
      }
    } catch (e) {
      debugPrint("Sync Metadata Kayıt Hatası: $e");
    }

    String? userMsg;
    if (!isAllSynced) {
      if (!notifSuccess && !calSuccess) {
        userMsg = 'Bildirim ve takvim senkronize edilemedi.';
      } else if (!notifSuccess) {
        userMsg = notifError ?? 'Bildirim kurulamadı.';
      } else {
        userMsg = calError ?? 'Takvim eşitlenemedi.';
      }
    }

    return TaskSyncResult(
      isFullySynced: isAllSynced,
      effectiveUserMessage: userMsg,
      notificationSuccess: notifSuccess,
      calendarSuccess: calSuccess,
    );
  }

  static Future<int> reconcilePendingAndFailedTasks() async {
    final user = supabase.auth.currentUser;
    if (user == null) return 0;

    int reconciledCount = 0;
    try {
      final res = await supabase
          .from('weekly_tasks')
          .select()
          .eq('user_id', user.id)
          .neq('sync_status', 'synced')
          .limit(10);

      for (var row in res) {
        final task = TaskItem.fromJson(row);
        final date =
            DateTime.tryParse(task.scheduledDate ?? '') ?? DateTime.now();
        final syncRes = await coordinateTaskSync(task: task, targetDate: date);
        if (syncRes.isFullySynced) {
          reconciledCount++;
        }
      }
    } catch (e) {
      debugPrint("Outbox Reconcile Hatası: $e");
    }
    return reconciledCount;
  }

  void triggerSync() {
    reconcilePendingAndFailedTasks();
  }
}
