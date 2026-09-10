import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest_all.dart' as tz_data;
import '../domain/models/task_item.dart';

enum NotificationScheduleStatus {
  scheduled,
  skippedPast,
  skippedNoReminder,
  failed,
}

class NotificationScheduleResult {
  final NotificationScheduleStatus status;
  final String? message;

  const NotificationScheduleResult({required this.status, this.message});

  bool get isScheduled => status == NotificationScheduleStatus.scheduled;
}

Function(String taskId)? onGlobalNotificationPayloadReceived;

class NotificationService {
  static final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();

  static int resolveNotificationId({required TaskItem task}) {
    if (task.notificationId != null && task.notificationId! > 0) {
      return task.notificationId!;
    }
    return (task.id.hashCode & 0x7fffffff);
  }

  static Future<void> initialize() async {
    try {
      tz_data.initializeTimeZones();
      const String currentTimeZone = 'Europe/Istanbul';
      tz.setLocalLocation(tz.getLocation(currentTimeZone));

      const AndroidInitializationSettings androidSettings =
          AndroidInitializationSettings('@mipmap/ic_launcher');

      const DarwinInitializationSettings iosSettings =
          DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: true,
        requestSoundPermission: true,
      );

      const InitializationSettings initSettings = InitializationSettings(
        android: androidSettings,
        iOS: iosSettings,
        macOS: iosSettings,
      );

      await _notificationsPlugin.initialize(
        initSettings,
        onDidReceiveNotificationResponse: (NotificationResponse response) {
          final payload = response.payload;
          if (payload != null && payload.isNotEmpty) {
            debugPrint("Bildirime tıklandı, hedef payload: $payload");
            onGlobalNotificationPayloadReceived?.call(payload);
          }
        },
      );

      final androidPlugin =
          _notificationsPlugin.resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      if (androidPlugin != null) {
        await androidPlugin.requestNotificationsPermission();
      }
    } catch (e) {
      debugPrint("Bildirim başlatma hatası: $e");
    }
  }

  static Future<NotificationScheduleResult> scheduleTaskReminder({
    required TaskItem task,
    required DateTime targetDate,
  }) async {
    try {
      if (task.reminderTime == 'Yok' || task.reminderTime.isEmpty) {
        return const NotificationScheduleResult(
          status: NotificationScheduleStatus.skippedNoReminder,
          message: 'Hatırlatıcı kapalı.',
        );
      }

      int minutesBefore = 60;
      if (task.reminderTime == '30 Dakika Önce') {
        minutesBefore = 30;
      }
      if (task.reminderTime == '15 Dakika Önce') {
        minutesBefore = 15;
      }
      if (task.reminderTime == '1 Gün Önce') {
        minutesBefore = 1440;
      }

      int hour = 10;
      int minute = 0;
      final parts = task.taskTime.split(':');
      if (parts.length == 2) {
        hour = int.tryParse(parts[0]) ?? 10;
        minute = int.tryParse(parts[1]) ?? 0;
      }

      final taskDateTime = DateTime(
        targetDate.year,
        targetDate.month,
        targetDate.day,
        hour,
        minute,
      );

      final reminderDateTime =
          taskDateTime.subtract(Duration(minutes: minutesBefore));

      if (reminderDateTime.isBefore(DateTime.now())) {
        return const NotificationScheduleResult(
          status: NotificationScheduleStatus.skippedPast,
          message: 'Hatırlatma zamanı geçmişte kaldı.',
        );
      }

      final tz.TZDateTime scheduledDate =
          tz.TZDateTime.from(reminderDateTime, tz.local);
      final int notifId = resolveNotificationId(task: task);

      const AndroidNotificationDetails androidDetails =
          AndroidNotificationDetails(
        'weekly_pulse_reminders',
        'Görev Hatırlatıcıları',
        channelDescription: 'Planlanan görevler için hatırlatma bildirimleri',
        importance: Importance.max,
        priority: Priority.high,
      );

      const DarwinNotificationDetails iosDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      );

      const NotificationDetails platformDetails = NotificationDetails(
        android: androidDetails,
        iOS: iosDetails,
        macOS: iosDetails,
      );

      await _notificationsPlugin.zonedSchedule(
        notifId,
        'Planın Yaklaşıyor! ⚡',
        '${task.title} saati geldi (${task.taskTime})',
        scheduledDate,
        platformDetails,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        payload: task.id,
      );

      return const NotificationScheduleResult(
        status: NotificationScheduleStatus.scheduled,
      );
    } catch (e) {
      debugPrint("Bildirim planlama hatası: $e");
      return NotificationScheduleResult(
        status: NotificationScheduleStatus.failed,
        message: e.toString(),
      );
    }
  }

  static Future<void> cancelNotification(int id) async {
    try {
      await _notificationsPlugin.cancel(id);
    } catch (e) {
      debugPrint("Bildirim iptal hatası ($id): $e");
    }
  }

  static Future<void> cancelAllNotifications() async {
    try {
      await _notificationsPlugin.cancelAll();
    } catch (e) {
      debugPrint("Tüm bildirimleri iptal etme hatası: $e");
    }
  }

  static Future<void> scheduleWeeklyReportNotification({
    required String userTierName,
  }) async {
    try {
      final now = DateTime.now();
      int daysUntilSunday = (DateTime.sunday - now.weekday) % 7;
      if (daysUntilSunday == 0 && now.hour >= 20) {
        daysUntilSunday = 7;
      }
      final nextSunday =
          DateTime(now.year, now.month, now.day + daysUntilSunday, 20, 0);
      final tzScheduled = tz.TZDateTime.from(nextSunday, tz.local);

      const AndroidNotificationDetails androidDetails =
          AndroidNotificationDetails(
        'weekly_pulse_intelligence',
        'Haftalık Raporlar',
        channelDescription: 'Haftalık yaşam ve plan analizi rapor bildirimleri',
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
      );
      const DarwinNotificationDetails iosDetails = DarwinNotificationDetails();
      const NotificationDetails platformDetails = NotificationDetails(
        android: androidDetails,
        iOS: iosDetails,
      );

      await _notificationsPlugin.zonedSchedule(
        99999,
        'Haftalık Zeka Raporun Hazır! 📊',
        'Geçen haftanın analizi tamamlandı. Yeni haftanı dengelemek için dokun.',
        tzScheduled,
        platformDetails,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
      );
    } catch (e) {
      debugPrint("Haftalık rapor bildirimi kurulamadı: $e");
    }
  }
}
