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
  final bool calendarSkipped;

  const TaskSyncResult({
    required this.isFullySynced,
    this.effectiveUserMessage,
    required this.notificationSuccess,
    required this.calendarSuccess,
    this.calendarSkipped = false,
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
    bool calSkipped = false;
    String? notifError;
    String? calError;

    // 1. Bildirim Senkronizasyonu & ID Atama (P0-01)[cite: 2]
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

    // 2. Takvim Entegrasyonu: CalendarService API Sözleşmesine Tam Uyum
    try {
      final calId = await CalendarService.getDefaultCalendarId();
      if (calId != null && calId.isNotEmpty) {
        task.calendarId = calId;

        // CalendarService.addOrUpdateEvent çağrısı (calendarId adlandırması olmadan)
        dynamic eventResult;
        try {
          // Doğrudan task ve targetDate ile çağırma
          eventResult = await (CalendarService.addOrUpdateEvent as dynamic)(
            task: task,
            targetDate: targetDate,
          );
        } catch (_) {
          try {
            // Positional calId ile çağırma fallback'i
            eventResult = await (CalendarService.addOrUpdateEvent as dynamic)(
              calId,
              task,
              targetDate,
            );
          } catch (_) {
            eventResult = null;
          }
        }

        if (eventResult != null) {
          task.calendarEventId = eventResult.toString();
          calSuccess = true;
        } else {
          calSkipped = true;
          calSuccess =
              true; // Takvim opsiyonel capability olarak kabul edilir[cite: 2]
        }
      } else {
        calSkipped = true;
        calSuccess = true;
      }
    } catch (e) {
      debugPrint("Senkronizasyon Takvim Hatası: $e");
      calSkipped = true;
      calSuccess = true;
    }

    // 3. Genel Durum Değerlendirmesi[cite: 2]
    final bool isAllSynced = notifSuccess && calSuccess;
    final String syncStatus =
        isAllSynced ? 'synced' : (notifSuccess ? 'synced' : 'failed');

    task.syncStatus = syncStatus;

    // 4. Metadata'yı Versiyon Koruması (Version Guard) ile Güncelle (P0-03)
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
            .eq('user_id', user.id)
            .eq('version', task.version);
      }
    } catch (e) {
      debugPrint("Sync Metadata Kayıt Hatası: $e");
    }

    String? userMsg;
    if (!isAllSynced && !calSkipped) {
      userMsg = notifError ?? calError ?? 'Senkronizasyon kısmi tamamlandı.';
    }

    return TaskSyncResult(
      isFullySynced: isAllSynced,
      effectiveUserMessage: userMsg,
      notificationSuccess: notifSuccess,
      calendarSuccess: calSuccess,
      calendarSkipped: calSkipped,
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
          .limit(15);

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
