import 'package:device_calendar/device_calendar.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/timezone.dart' as tz;
import '../domain/models/task_item.dart';

class CalendarService {
  static final DeviceCalendarPlugin _deviceCalendarPlugin =
      DeviceCalendarPlugin();
  static const String _prefCalendarKey = 'selected_calendar_id';

  static Future<bool> requestPermissions() async {
    var permissionsGranted = await _deviceCalendarPlugin.hasPermissions();
    if (permissionsGranted.isSuccess && !permissionsGranted.data!) {
      permissionsGranted = await _deviceCalendarPlugin.requestPermissions();
      return permissionsGranted.isSuccess && permissionsGranted.data!;
    }
    return permissionsGranted.isSuccess && permissionsGranted.data!;
  }

  static Future<List<Calendar>> getWritableCalendars() async {
    final hasPermission = await requestPermissions();
    if (!hasPermission) return [];

    final calendarsResult = await _deviceCalendarPlugin.retrieveCalendars();
    if (calendarsResult.isSuccess && calendarsResult.data != null) {
      return calendarsResult.data!.where((c) => c.isReadOnly == false).toList();
    }
    return [];
  }

  static Future<void> setSelectedCalendarId(String calendarId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefCalendarKey, calendarId);
  }

  static Future<String?> getDefaultCalendarId() async {
    final prefs = await SharedPreferences.getInstance();
    final savedId = prefs.getString(_prefCalendarKey);
    if (savedId != null && savedId.isNotEmpty) {
      return savedId;
    }

    final writable = await getWritableCalendars();
    if (writable.isNotEmpty) {
      // Birincil veya varsayılan takvimi tercih et
      final primary = writable.firstWhere(
        (c) => c.isDefault == true,
        orElse: () => writable.first,
      );
      await setSelectedCalendarId(primary.id!);
      return primary.id;
    }
    return null;
  }

  static Future<String?> addOrUpdateEvent({
    required TaskItem task,
    required DateTime targetDate,
  }) async {
    try {
      final calendarId = await getDefaultCalendarId();
      if (calendarId == null) return null;

      final startTime = task.startDateTime;
      final start = DateTime(
        targetDate.year,
        targetDate.month,
        targetDate.day,
        startTime.hour,
        startTime.minute,
      );
      final end = start.add(Duration(minutes: task.durationMinutes));

      final event = Event(
        calendarId,
        eventId: task.calendarEventId,
        title: '[WeeklyPulse] ${task.title}',
        description: 'Öncelik: ${task.priority}\nKategori: ${task.category}',
        start: tz.TZDateTime.from(start, tz.local),
        end: tz.TZDateTime.from(end, tz.local),
      );

      // Event dışarıdan silinmişse (recovery): update dene, olmazsa yeni event oluştur
      if (task.calendarEventId != null && task.calendarEventId!.isNotEmpty) {
        final updateResult =
            await _deviceCalendarPlugin.createOrUpdateEvent(event);
        if (updateResult?.isSuccess == true && updateResult?.data != null) {
          return updateResult!.data;
        }
      }

      // Yeni etkinlik oluştur
      event.eventId = null;
      final createResult =
          await _deviceCalendarPlugin.createOrUpdateEvent(event);
      if (createResult?.isSuccess == true) {
        return createResult?.data;
      }
      return null;
    } catch (e) {
      debugPrint("Calendar addOrUpdateEvent Hatası: $e");
      return null;
    }
  }

  static Future<bool> deleteEvent(String calendarId, String eventId) async {
    try {
      final hasPermission = await requestPermissions();
      if (!hasPermission) return false;

      final res = await _deviceCalendarPlugin.deleteEvent(calendarId, eventId);
      // Etkinlik zaten yoksa da silinmiş kabul edilir
      return res.isSuccess;
    } catch (e) {
      debugPrint("Calendar deleteEvent Hatası: $e");
      return false;
    }
  }
}
