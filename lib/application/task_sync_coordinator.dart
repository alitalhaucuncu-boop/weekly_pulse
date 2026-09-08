import 'package:flutter/foundation.dart';
import '../../core/constants.dart';
import '../../data/notification_service.dart';
import '../../data/calendar_service.dart';
import '../../domain/models/task_item.dart';

class TaskSyncResult {
  final bool isDbPersisted;
  final bool notifSuccess;
  final String? calendarEventId;
  final String? syncWarning;
  final String? syncErrorCode;

  const TaskSyncResult({
    required this.isDbPersisted,
    required this.notifSuccess,
    this.calendarEventId,
    this.syncWarning,
    this.syncErrorCode,
  });

  bool get isFullySynced =>
      isDbPersisted && notifSuccess && calendarEventId != null;
  bool get isPartialSynced =>
      isDbPersisted && (!notifSuccess || calendarEventId == null);

  String? get effectiveUserMessage {
    if (isFullySynced) return null;
    if (!isDbPersisted) return 'Veritabanı kaydı başarısız.';
    if (!notifSuccess && calendarEventId == null)
      return 'Bildirim ve Takvim eşitlenemedi.';
    if (!notifSuccess) return 'Bildirim planlanamadı.';
    if (calendarEventId == null) return 'Takvim etkinliği oluşturulamadı.';
    return syncWarning ?? 'Kısmi senkronizasyon hatası.';
  }
}

class TaskSyncCoordinator {
  static Future<TaskSyncResult> coordinateTaskSync({
    required TaskItem task,
    required DateTime targetDate,
    bool enqueueOutbox = true,
  }) async {
    final user = supabase.auth.currentUser;
    if (user == null) {
      return const TaskSyncResult(
        isDbPersisted: false,
        notifSuccess: false,
        syncErrorCode: 'unauthorized',
        syncWarning: 'Oturum bulunamadı.',
      );
    }

    bool notifSuccess = false;
    String? calendarEventId;
    String? syncWarning;
    String? syncErrorCode;

    try {
      final notifStatus = await NotificationService.scheduleTaskNotification(
        task: task,
        targetDate: targetDate,
      );

      notifSuccess = (notifStatus == NotificationScheduleStatus.scheduled ||
          notifStatus == NotificationScheduleStatus.skippedNoReminder ||
          notifStatus == NotificationScheduleStatus.skippedPast);

      if (!notifSuccess) {
        syncErrorCode = notifStatus.name;
        syncWarning = 'Bildirim durumu: ${notifStatus.name}';
      }
    } catch (e) {
      debugPrint("Senkronizasyon Bildirim Hatası: $e");
      syncErrorCode = 'notification_exception';
      syncWarning = 'Bildirim servisi hatası.';
    }

    try {
      calendarEventId = await CalendarService.addOrUpdateEvent(
        task: task,
        targetDate: targetDate,
      );
      if (calendarEventId == null && syncErrorCode == null) {
        syncErrorCode = 'calendar_failed';
        syncWarning = 'Takvim etkinliği oluşturulamadı.';
      }
    } catch (e) {
      debugPrint("Senkronizasyon Takvim Hatası: $e");
      syncErrorCode = 'calendar_exception';
      syncWarning = 'Takvim servisi hatası.';
    }

    final effectiveCalendarEventId = calendarEventId ?? task.calendarEventId;
    final effectiveCalendarId = task.calendarId;

    final bool isFullySynced = notifSuccess && effectiveCalendarEventId != null;
    final bool isPartial = notifSuccess || effectiveCalendarEventId != null;
    final String syncStatus =
        isFullySynced ? 'synced' : (isPartial ? 'partial' : 'failed');
    bool dbPersisted = false;

    try {
      final updateRes = await supabase
          .from('weekly_tasks')
          .update({
            'sync_status': syncStatus,
            'sync_warning': syncWarning,
            'sync_error_code': syncErrorCode,
            'calendar_id': effectiveCalendarId,
            'calendar_event_id': effectiveCalendarEventId,
            'last_synced_at': DateTime.now().toIso8601String(),
            'version': task.version,
          })
          .eq('id', task.id)
          .eq('user_id', user.id)
          .select('id')
          .maybeSingle();

      dbPersisted = (updateRes != null);
      if (dbPersisted) {
        task.calendarEventId = effectiveCalendarEventId;
      }
    } catch (e) {
      debugPrint("DB Senkronizasyon Durumu Güncelleme Hatası: $e");
      dbPersisted = false;
    }

    if (dbPersisted && !isFullySynced && enqueueOutbox) {
      try {
        final idempotencyKey = "sync_${task.id}_v${task.version}";
        await supabase.from('sync_operations').upsert({
          'user_id': user.id,
          'task_id': task.id,
          'operation_type': 'sync_task',
          'idempotency_key': idempotencyKey,
          'state_version': task.version,
          'desired_state': {
            'target_date': targetDate.toIso8601String(),
            'task_time': task.taskTime,
            'duration_minutes': task.durationMinutes,
            'title': task.title,
            'calendar_id': effectiveCalendarId,
            'calendar_event_id': effectiveCalendarEventId,
          },
          'status': 'pending',
          'last_error': syncWarning ?? 'Arka plan eşitlemesi bekleniyor',
        }, onConflict: 'user_id,idempotency_key');
      } catch (e) {
        debugPrint("Outbox Enqueue Hatası: $e");
      }
    }

    return TaskSyncResult(
      isDbPersisted: dbPersisted,
      notifSuccess: notifSuccess,
      calendarEventId: effectiveCalendarEventId,
      syncWarning: syncWarning,
      syncErrorCode: syncErrorCode,
    );
  }

  static Future<int> reconcilePendingAndFailedTasks() async {
    final user = supabase.auth.currentUser;
    if (user == null) return 0;

    int reconciledCount = 0;

    try {
      final dynamic claimedRes =
          await supabase.rpc('claim_sync_operations', params: {
        'p_limit': 20,
        'p_lock_seconds': 60,
      });

      if (claimedRes is List && claimedRes.isNotEmpty) {
        for (var op in claimedRes) {
          final opId = op['id'];
          final taskId = op['task_id'];
          final opType = op['operation_type']?.toString() ?? 'sync_task';
          final opVersion = op['state_version'] is int
              ? op['state_version'] as int
              : int.tryParse(op['state_version']?.toString() ?? '1') ?? 1;

          if (opId == null) continue;

          // Fail-Closed Durable Deletion İşleyicisi
          if (opType == 'delete_task') {
            final desired = op['desired_state'] as Map<String, dynamic>?;
            final calId = desired?['calendar_id']?.toString();
            final calEventId = desired?['calendar_event_id']?.toString();

            int? notifId;
            final rawNotifId = desired?['notification_id'];
            if (rawNotifId is int) {
              notifId = rawNotifId;
            } else if (rawNotifId != null) {
              notifId = int.tryParse(rawNotifId.toString());
            }

            bool calDeleted = true;
            bool notifCancelled = true;
            String? deleteError;

            if (calEventId != null && calEventId.isNotEmpty) {
              try {
                final cId = (calId != null && calId.isNotEmpty) ? calId : '';
                await CalendarService.deleteEvent(cId, calEventId);
              } catch (e) {
                debugPrint("Kuyruk Takvim Silme Hatası: $e");
                calDeleted = false;
                deleteError = 'Takvim etkinliği silinemedi: $e';
              }
            }

            if (notifId != null) {
              try {
                await NotificationService.cancelNotification(notifId);
              } catch (e) {
                debugPrint("Kuyruk Bildirim İptal Hatası: $e");
                notifCancelled = false;
                deleteError = (deleteError == null)
                    ? 'Bildirim iptal edilemedi: $e'
                    : '$deleteError | Bildirim iptal hatası';
              }
            }

            // İki servis de hatasız temizlendiyse complete et; aksi halde fail et
            if (calDeleted && notifCancelled) {
              final completeRes =
                  await supabase.rpc('complete_sync_operation', params: {
                'p_operation_id': opId,
                'p_state_version': opVersion,
              });
              if (completeRes is Map && completeRes['success'] == true) {
                reconciledCount++;
              }
            } else {
              await supabase.rpc('fail_sync_operation', params: {
                'p_operation_id': opId,
                'p_state_version': opVersion,
                'p_error_message':
                    deleteError ?? 'Harici kayıtlar temizlenemedi.',
              });
            }
            continue;
          }

          if (taskId == null) {
            await supabase.rpc('cancel_sync_operation', params: {
              'p_operation_id': opId,
              'p_reason': 'Geçersiz operasyon parametreleri.',
            });
            continue;
          }

          final taskRes = await supabase
              .from('weekly_tasks')
              .select()
              .eq('id', taskId)
              .eq('user_id', user.id)
              .maybeSingle();

          if (taskRes != null) {
            final task = TaskItem.fromJson(taskRes);

            if (task.version > opVersion) {
              await supabase.rpc('cancel_sync_operation', params: {
                'p_operation_id': opId,
                'p_reason':
                    'Daha yeni bir görev versiyonu mevcut (Stale Operation).',
              });
              continue;
            }

            final targetDate =
                DateTime.tryParse(task.scheduledDate ?? '') ?? DateTime.now();

            final res = await coordinateTaskSync(
              task: task,
              targetDate: targetDate,
              enqueueOutbox: false,
            );

            if (res.isFullySynced) {
              final completeRes =
                  await supabase.rpc('complete_sync_operation', params: {
                'p_operation_id': opId,
                'p_state_version': opVersion,
              });
              if (completeRes is Map && completeRes['success'] == true) {
                reconciledCount++;
              }
            } else {
              await supabase.rpc('fail_sync_operation', params: {
                'p_operation_id': opId,
                'p_state_version': opVersion,
                'p_error_message':
                    res.effectiveUserMessage ?? 'Senkronizasyon hatası.',
              });
            }
          } else {
            await supabase.rpc('cancel_sync_operation', params: {
              'p_operation_id': opId,
              'p_reason': 'Görev silinmiş, operasyon iptal edildi.',
            });
          }
        }
      }
    } catch (e) {
      debugPrint("Reconciliation Hatası: $e");
    }

    return reconciledCount;
  }
}
