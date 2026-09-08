import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;
import '../domain/models/task_item.dart';

enum NotificationScheduleStatus {
  scheduled,
  skippedPast,
  skippedNoReminder,
  failed,
}

class NotificationService {
  static final FlutterLocalNotificationsPlugin plugin =
      FlutterLocalNotificationsPlugin();

  static int resolveNotificationId({required TaskItem task}) {
    if (task.notificationId != null && task.notificationId! > 0) {
      return task.notificationId!;
    }
    int hash = 5381;
    final String raw = task.id.isNotEmpty
        ? task.id
        : "${task.title}_${task.weekStartDate}_${task.dayIndex}";
    for (int i = 0; i < raw.length; i++) {
      hash = ((hash << 5) + hash) + raw.codeUnitAt(i);
      hash = hash & 0x7FFFFFFF;
    }
    return hash;
  }

  static Future<NotificationScheduleStatus> scheduleTaskNotification({
    required TaskItem task,
    required DateTime targetDate,
  }) async {
    try {
      if (task.reminderTime == 'Hatırlatma Yok') {
        final int notifId = resolveNotificationId(task: task);
        await cancelNotification(notifId);
        return NotificationScheduleStatus.skippedNoReminder;
      }

      final int notifId = resolveNotificationId(task: task);
      await cancelNotification(notifId);

      int h = 10, m = 0;
      try {
        final parts = task.taskTime.split(':');
        if (parts.length == 2) {
          h = int.parse(parts[0]);
          m = int.parse(parts[1]);
        }
      } catch (_) {}

      final taskDateTime = DateTime(
        targetDate.year,
        targetDate.month,
        targetDate.day,
        h,
        m,
      );

      Duration offset = Duration.zero;
      if (task.reminderTime == '10 Dakika Önce') {
        offset = const Duration(minutes: 10);
      } else if (task.reminderTime == '15 Dakika Önce') {
        offset = const Duration(minutes: 15);
      } else if (task.reminderTime == '30 Dakika Önce') {
        offset = const Duration(minutes: 30);
      } else if (task.reminderTime == '1 Saat Önce') {
        offset = const Duration(hours: 1);
      } else if (task.reminderTime == '3 Saat Önce') {
        offset = const Duration(hours: 3);
      } else if (task.reminderTime == '1 Gün Önce') {
        offset = const Duration(days: 1);
      } else if (task.reminderTime == '2 Gün Önce') {
        offset = const Duration(days: 2);
      }

      final scheduledTime = taskDateTime.subtract(offset);

      if (scheduledTime.isBefore(DateTime.now())) {
        return NotificationScheduleStatus.skippedPast;
      }

      final tzScheduled = tz.TZDateTime.from(scheduledTime, tz.local);

      const AndroidNotificationDetails androidDetails =
          AndroidNotificationDetails(
        'weeklypulse_tasks',
        'Görev Hatırlatıcıları',
        channelDescription: 'Planlanan görevler için hatırlatma bildirimleri',
        importance: Importance.max,
        priority: Priority.high,
      );

      const NotificationDetails details = NotificationDetails(
        android: androidDetails,
        iOS: DarwinNotificationDetails(presentAlert: true, presentSound: true),
      );

      await plugin.zonedSchedule(
        notifId,
        '⏰ ${task.title}',
        '${task.taskTime} saatindeki planınız yaklaşıyor.',
        tzScheduled,
        details,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        payload: task.id,
      );

      return NotificationScheduleStatus.scheduled;
    } catch (e) {
      debugPrint("Bildirim Planlama Hatası: $e");
      return NotificationScheduleStatus.failed;
    }
  }

  static Future<void> cancelNotification(int id) async {
    try {
      await plugin.cancel(id);
    } catch (e) {
      debugPrint("Bildirim İptal Hatası: $e");
    }
  }

  static Future<void> scheduleWeeklyReportNotification(
      {required String userTierName}) async {
    try {
      await cancelNotification(99999);
      final now = DateTime.now();
      int daysUntilSunday = DateTime.sunday - now.weekday;
      if (daysUntilSunday < 0 || (daysUntilSunday == 0 && now.hour >= 20)) {
        daysUntilSunday += 7;
      }

      final targetSunday =
          DateTime(now.year, now.month, now.day + daysUntilSunday, 20, 0);
      final tzSunday = tz.TZDateTime.from(targetSunday, tz.local);

      const AndroidNotificationDetails androidDetails =
          AndroidNotificationDetails(
        'weeklypulse_reports',
        'Haftalık Zeka Raporları',
        channelDescription: 'Pazar akşamı haftalık özet bildirimleri',
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
      );

      await plugin.zonedSchedule(
        99999,
        '👑 Haftalık Yaşam Raporunuz Hazır!',
        '$userTierName üyeliğinize özel bütünsel zeka analizi hazırlandı.',
        tzSunday,
        const NotificationDetails(android: androidDetails),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        matchDateTimeComponents: DateTimeComponents.dayOfWeekAndTime,
      );
    } catch (_) {}
  }
}
