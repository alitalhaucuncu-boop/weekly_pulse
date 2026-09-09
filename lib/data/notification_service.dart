import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:flutter_timezone/flutter_timezone.dart';

import '../domain/models/task_item.dart';

enum NotificationScheduleResult {
  scheduled,
  skippedPast,
  skippedNoReminder,
  failed,
}

class NotificationService {
  static final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();

  static FlutterLocalNotificationsPlugin get plugin => _notificationsPlugin;

  static bool _isInitialized = false;

  static int resolveNotificationId({required TaskItem task}) {
    if (task.notificationId != null && task.notificationId! > 0) {
      return task.notificationId!;
    }
    if (task.id.isNotEmpty) {
      final int hash = task.id.hashCode.abs();
      return hash % 2147483647;
    }
    return DateTime.now().millisecondsSinceEpoch % 2147483647;
  }

  static Future<void> initialize() async {
    if (_isInitialized) return;

    tz_data.initializeTimeZones();
    try {
      final dynamic tzResult = await FlutterTimezone.getLocalTimezone();
      final String currentTimeZone =
          tzResult is String ? tzResult : tzResult.toString();
      tz.setLocalLocation(tz.getLocation(currentTimeZone));
    } catch (e) {
      debugPrint("Saat Dilimi Hatası (UTC fallback): $e");
      tz.setLocalLocation(tz.UTC);
    }

    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    const DarwinInitializationSettings initializationSettingsDarwin =
        DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    const InitializationSettings initializationSettings =
        InitializationSettings(
      android: initializationSettingsAndroid,
      iOS: initializationSettingsDarwin,
    );

    await _notificationsPlugin.initialize(
      initializationSettings,
      onDidReceiveNotificationResponse: (NotificationResponse response) {
        debugPrint("Bildirime tıklandı: ${response.payload}");
      },
    );

    _isInitialized = true;
  }

  static Future<NotificationScheduleResult> scheduleTaskNotification({
    required TaskItem task,
    required DateTime targetDate,
  }) async {
    await initialize();

    if (task.reminderTime == 'Hatırlatma Yok') {
      return NotificationScheduleResult.skippedNoReminder;
    }

    final int notifId = resolveNotificationId(task: task);

    int hour = 10;
    int minute = 0;
    final timeParts = task.taskTime.split(':');
    if (timeParts.length == 2) {
      hour = int.tryParse(timeParts[0]) ?? 10;
      minute = int.tryParse(timeParts[1]) ?? 0;
    }

    DateTime taskScheduledDateTime = DateTime(
      targetDate.year,
      targetDate.month,
      targetDate.day,
      hour,
      minute,
    );

    int reminderOffsetMinutes = 60;
    if (task.reminderTime == 'Zamanında') {
      reminderOffsetMinutes = 0;
    } else if (task.reminderTime == '10 Dakika Önce') {
      reminderOffsetMinutes = 10;
    } else if (task.reminderTime == '30 Dakika Önce') {
      reminderOffsetMinutes = 30;
    } else if (task.reminderTime == '1 Saat Önce') {
      reminderOffsetMinutes = 60;
    } else if (task.reminderTime == '1 Gün Önce') {
      reminderOffsetMinutes = 1440;
    }

    final DateTime triggerDateTime = taskScheduledDateTime.subtract(
      Duration(minutes: reminderOffsetMinutes),
    );

    if (triggerDateTime.isBefore(DateTime.now())) {
      return NotificationScheduleResult.skippedPast;
    }

    const AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
      'weekly_pulse_tasks_channel',
      'Görev Hatırlatıcıları',
      channelDescription:
          'Haftalık planlanan görevler için hatırlatma bildirimleri',
      importance: Importance.max,
      priority: Priority.high,
    );

    const NotificationDetails notificationDetails =
        NotificationDetails(android: androidDetails);

    try {
      await _notificationsPlugin.zonedSchedule(
        notifId,
        'Görev Vakti: ${task.title}',
        'Öncelik: ${task.priority} | Süre: ${task.durationMinutes} dk',
        tz.TZDateTime.from(triggerDateTime, tz.local),
        notificationDetails,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        payload: task.id,
      );
      return NotificationScheduleResult.scheduled;
    } catch (e) {
      debugPrint("Bildirim Planlama Hatası: $e");
      return NotificationScheduleResult.failed;
    }
  }

  static Future<bool> cancelNotification(int id) async {
    try {
      await initialize();
      await _notificationsPlugin.cancel(id);
      return true;
    } catch (e) {
      debugPrint("Bildirim İptal Hatası ($id): $e");
      return false;
    }
  }

  static Future<bool> cancelAllNotifications() async {
    try {
      await initialize();
      await _notificationsPlugin.cancelAll();
      return true;
    } catch (e) {
      debugPrint("Tüm Bildirimleri İptal Hatası: $e");
      return false;
    }
  }

  static Future<void> scheduleWeeklyReportNotification({
    required String userTierName,
  }) async {
    await initialize();
    const int reportNotifId = 99999;

    const AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
      'weekly_pulse_report_channel',
      'Haftalık Raporlar',
      channelDescription: 'Haftalık zeka ve verimlilik raporları',
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
    );

    const NotificationDetails notificationDetails =
        NotificationDetails(android: androidDetails);

    try {
      await _notificationsPlugin.show(
        reportNotifId,
        'Haftalık Zeka Raporun Hazır! 📊',
        '$userTierName üyesi olarak yeni haftanın verimlilik analizini incele.',
        notificationDetails,
      );
    } catch (e) {
      debugPrint("Haftalık Rapor Bildirim Hatası: $e");
    }
  }
}
