import 'package:flutter/foundation.dart';
import '../core/constants.dart';
import '../domain/models/task_item.dart';
import '../data/notification_service.dart';
import '../data/calendar_service.dart';

class TaskSyncResult {
  final bool isNotificationSynced;
  final bool isCalendarSynced;
  final String? notificationMessage;
  final String? calendarMessage;

  const TaskSyncResult({
    required this.isNotificationSynced,
    required this.isCalendarSynced,
    this.notificationMessage,
    this.calendarMessage,
  });

  bool get isFullySynced => isNotificationSynced && isCalendarSynced;

  String? get effectiveUserMessage {
    if (isFullySynced) return null;
    List<String> errors = [];
    if (!isNotificationSynced && notificationMessage != null) {
      errors.add(notificationMessage!);
    }
    if (!isCalendarSynced && calendarMessage != null) {
      errors.add(calendarMessage!);
    }
    return errors.join(" ");
  }
}

class TaskSyncCoordinator {
  // WP-005 FIX: Per-task paralel sync kilit seti
  static final Set<String> _activeSyncTaskIds = <String>{};

  static Future<TaskSyncResult> coordinateTaskSync({
    required TaskItem task,
    required DateTime targetDate,
  }) async {
    if (!_activeSyncTaskIds.add(task.id)) {
      return const TaskSyncResult(
        isNotificationSynced: true,
        isCalendarSynced: true,
        calendarMessage: 'Senkronizasyon zaten sürüyor.',
      );
    }

    try {
      bool notifSuccess = true;
      String? notifMsg;
      int notifId = NotificationService.resolveNotificationId(task: task);

      if (task.isCompleted) {
        await NotificationService.cancelNotification(notifId);
        notifMsg = 'Görev tamamlandı, bildirim kaldırıldı.';
      } else {
        final notifResult = await NotificationService.scheduleTaskReminder(
          task: task,
          targetDate: targetDate,
        );
        notifSuccess = notifResult.isScheduled ||
            notifResult.status ==
                NotificationScheduleStatus.skippedNoReminder ||
            notifResult.status == NotificationScheduleStatus.skippedPast;
        notifMsg = notifResult.message;
      }

      bool calSuccess = true;
      String? calMsg;
      String? externalCalId = task.calendarId;
      String? externalEventId = task.calendarEventId;

      // WP-006 FIX: Görev tamamlandıysa takvimden sil, aksi halde ekle/güncelle
      if (task.isCompleted) {
        if (externalCalId != null && externalEventId != null) {
          await CalendarService.deleteEvent(externalCalId, externalEventId);
          externalEventId = null;
        }
      } else {
        final calId = await CalendarService.getDefaultCalendarId();
        if (calId != null) {
          externalCalId = calId;
          final eventId = await CalendarService.addOrUpdateEvent(
            calendarId: calId,
            existingEventId: task.calendarEventId,
            title: task.title,
            startTime: task.startDateTime,
            durationMinutes: task.durationMinutes,
            description:
                "WeeklyPulse ${task.taskMode == 'student' ? 'Akademik' : 'İş'} Planı",
          );
          if (eventId != null) {
            externalEventId = eventId;
          } else {
            calSuccess = false;
            calMsg = 'Takvim eşitlenemedi.';
          }
        } else {
          calSuccess = false;
          calMsg = 'Yazılabilir takvim bulunamadı.';
        }
      }

      try {
        final user = supabase.auth.currentUser;
        if (user != null) {
          final newStatus = (notifSuccess && calSuccess) ? 'synced' : 'partial';
          await supabase
              .from('weekly_tasks')
              .update({
                'notification_id': notifId,
                'calendar_id': externalCalId,
                'calendar_event_id': externalEventId,
                'sync_status': newStatus,
                'last_synced_at': DateTime.now().toIso8601String(),
              })
              .eq('id', task.id)
              .eq('user_id', user.id);
        }
      } catch (e) {
        debugPrint("Metadata güncelleme hatası: $e");
      }

      return TaskSyncResult(
        isNotificationSynced: notifSuccess,
        isCalendarSynced: calSuccess,
        notificationMessage: notifMsg,
        calendarMessage: calMsg,
      );
    } finally {
      _activeSyncTaskIds.remove(task.id);
    }
  }

  static Future<int> reconcilePendingAndFailedTasks() async {
    int reconciled = 0;
    try {
      final user = supabase.auth.currentUser;
      if (user == null) return 0;

      final dynamic claimRes = await supabase.rpc(
        'claim_pending_delete_operations',
        params: {'p_limit': 10, 'p_lease_seconds': 60},
      );

      if (claimRes is Map &&
          claimRes['success'] == true &&
          claimRes['operations'] != null) {
        final String? leaseToken = claimRes['lease_token'];
        final List ops = claimRes['operations'] as List;

        for (var op in ops) {
          final opId = op['id'];
          final desiredState = op['desired_state'] as Map?;
          final notifId = desiredState?['notification_id'];
          final calId = desiredState?['calendar_id'];
          final calEventId = desiredState?['calendar_event_id'];

          String notifStatus = 'skipped';
          if (notifId != null && notifId is int) {
            await NotificationService.cancelNotification(notifId);
            notifStatus = 'best_effort_client_ack';
          }

          String calStatus = 'skipped';
          String? verifiedEventId;
          if (calId != null && calEventId != null) {
            final deleted = await CalendarService.deleteEvent(
                calId.toString(), calEventId.toString());
            calStatus = deleted ? 'provider_verified' : 'provider_not_found';
            verifiedEventId = deleted ? calEventId.toString() : 'not_found';
          }

          if (leaseToken != null) {
            await supabase.rpc('report_delete_side_effects', params: {
              'p_operation_id': opId,
              'p_lease_token': leaseToken,
              'p_notification_status': notifStatus,
              'p_calendar_status': calStatus,
              'p_verified_event_id': verifiedEventId,
            });
            reconciled++;
          }
        }
      }
    } catch (e) {
      debugPrint("Reconciliation hatası: $e");
    }
    return reconciled;
  }
}
