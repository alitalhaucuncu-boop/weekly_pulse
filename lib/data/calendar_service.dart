import 'package:device_calendar/device_calendar.dart';
import 'package:flutter/foundation.dart';
import 'package:timezone/timezone.dart' as tz;
import '../domain/models/task_item.dart';

class CalendarService {
  static final DeviceCalendarPlugin _deviceCalendarPlugin =
      DeviceCalendarPlugin();

  static Future<String?> getDefaultCalendarId() async {
    try {
      var permissionsGranted = await _deviceCalendarPlugin.hasPermissions();
      if (permissionsGranted.isSuccess && !(permissionsGranted.data ?? false)) {
        permissionsGranted = await _deviceCalendarPlugin.requestPermissions();
        if (!permissionsGranted.isSuccess ||
            !(permissionsGranted.data ?? false)) {
          return null;
        }
      }
      final calendarsResult = await _deviceCalendarPlugin.retrieveCalendars();
      if (calendarsResult.isSuccess && calendarsResult.data != null) {
        final calendars = calendarsResult.data!;
        if (calendars.isNotEmpty) {
          return calendars.first.id;
        }
      }
    } catch (e) {
      debugPrint("Calendar permission/retrieve error: $e");
    }
    return null;
  }

  static Future<String?> addOrUpdateEvent({
    required TaskItem task,
    required DateTime targetDate,
  }) async {
    try {
      final calendarId = task.calendarId ?? await getDefaultCalendarId();
      if (calendarId == null) return null;
      task.calendarId = calendarId;

      int h = 10, m = 0;
      try {
        final parts = task.taskTime.split(':');
        if (parts.length == 2) {
          h = int.parse(parts[0]);
          m = int.parse(parts[1]);
        }
      } catch (_) {}

      final startDate =
          DateTime(targetDate.year, targetDate.month, targetDate.day, h, m);
      final endDate = startDate.add(Duration(minutes: task.durationMinutes));

      final event = Event(
        calendarId,
        eventId: task.calendarEventId,
        title: task.title,
        description: 'WeeklyPulse Planı: ${task.category}',
        start: tz.TZDateTime.from(startDate, tz.local),
        end: tz.TZDateTime.from(endDate, tz.local),
      );

      final result = await _deviceCalendarPlugin.createOrUpdateEvent(event);
      if (result != null && result.isSuccess && result.data != null) {
        return result.data;
      }
    } catch (e) {
      debugPrint("Calendar Add Event Error: $e");
    }
    return null;
  }

  static Future<bool> deleteEvent(String calendarId, String eventId) async {
    try {
      final result =
          await _deviceCalendarPlugin.deleteEvent(calendarId, eventId);
      return result.isSuccess && (result.data ?? false);
    } catch (e) {
      debugPrint("Calendar Delete Event Error: $e");
      return false;
    }
  }
}
