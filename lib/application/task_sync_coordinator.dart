import 'package:flutter/foundation.dart';
import '../../core/constants.dart';
import '../../domain/models/task_item.dart';
import '../../data/notification_service.dart';
import '../../data/calendar_service.dart';

enum CalendarSyncStatus { synced, skippedByUser, unavailable, failed }

class TaskSyncResult {
  final bool isFullySynced;
  final String? effectiveUserMessage;
  final bool notificationSuccess;
  final bool notificationSkippedPast;
  final CalendarSyncStatus calendarStatus;
  final bool isVersionConflict;

  const TaskSyncResult({
    required this.isFullySynced,
    this.effectiveUserMessage,
    required this.notificationSuccess,
    this.notificationSkippedPast = false,
    required this.calendarStatus,
    this.isVersionConflict = false,
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
    bool notifSkippedPast = false;
    CalendarSyncStatus calStatus = CalendarSyncStatus.unavailable;
    String? notifError;
    String? calError;
    bool isConflict = false;
    bool isNetworkOrDbError = false;

    // 1. Bildirim Senkronizasyonu
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
        if (statusStr.contains('scheduled') || scheduleStatus == true) {
          notifSuccess = true;
        } else if (statusStr.contains('skippedpast')) {
          notifSkippedPast = true;
          notifSuccess = false;
          notifError = 'Görev saati geçmiş olduğu için bildirim kurulmadı.';
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

    // 2. Takvim Entegrasyonu
    try {
      final calId = await CalendarService.getDefaultCalendarId();
      if (calId == null || calId.isEmpty) {
        calStatus = CalendarSyncStatus.skippedByUser;
      } else {
        task.calendarId = calId;

        final String? eventId = await CalendarService.addOrUpdateEvent(
          task: task,
          targetDate: targetDate,
        );

        if (eventId != null && eventId.isNotEmpty) {
          task.calendarEventId = eventId;
          calStatus = CalendarSyncStatus.synced;
        } else {
          calStatus = CalendarSyncStatus.failed;
          calError = 'Takvim etkinliği oluşturulamadı.';
        }
      }
    } catch (e) {
      debugPrint("Takvim Entegrasyon Hatası: $e");
      calStatus = CalendarSyncStatus.failed;
      calError = 'Takvim hatası: $e';
    }

    // 3. Durum Değerlendirmesi
    final bool calOk = (calStatus == CalendarSyncStatus.synced ||
        calStatus == CalendarSyncStatus.skippedByUser);
    final bool isAllSynced = notifSuccess && calOk;
    final String syncStatus = isAllSynced
        ? 'synced'
        : (notifSkippedPast && calOk ? 'partial' : 'failed');

    task.syncStatus = syncStatus;

    // 4. Metadata Güncellemesi: P1-08 Sıfır Satır (Conflict) ile Ağ Hatasını Ayırma
    try {
      final user = supabase.auth.currentUser;
      if (user != null && task.id.isNotEmpty) {
        final updateResponse = await supabase
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
            .eq('version', task.version)
            .select('id')
            .maybeSingle();

        if (updateResponse == null) {
          isConflict = true;
          debugPrint(
              "UYARI: Sync metadata zero-row update! Task version stale.");
        }
      }
    } catch (e) {
      debugPrint("Sync Metadata Ağ/Kayıt Hatası: $e");
      isNetworkOrDbError = true;
    }

    String? userMsg;
    if (isConflict) {
      userMsg = 'Görev başka bir cihazda değiştirilmiş (Versiyon uyuşmazlığı).';
    } else if (isNetworkOrDbError) {
      userMsg = 'Senkronizasyon sunucuya yazılamadı (Bağlantı hatası).';
    } else if (notifSkippedPast) {
      userMsg = 'Plan kaydedildi (Zamanı geçmiş bildirim planlanmadı).';
    } else if (!isAllSynced) {
      userMsg = notifError ?? calError ?? 'Senkronizasyon başarısız oldu.';
    }

    return TaskSyncResult(
      isFullySynced: isAllSynced && !isConflict && !isNetworkOrDbError,
      effectiveUserMessage: userMsg,
      notificationSuccess: notifSuccess,
      notificationSkippedPast: notifSkippedPast,
      calendarStatus: calStatus,
      isVersionConflict: isConflict,
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
