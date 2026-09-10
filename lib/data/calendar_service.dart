import 'package:flutter/foundation.dart';
import 'package:device_calendar/device_calendar.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/timezone.dart' as tz;

class CalendarService {
  static final DeviceCalendarPlugin _plugin = DeviceCalendarPlugin();

  static Future<bool> requestPermissions() async {
    try {
      var permissionsGranted = await _plugin.hasPermissions();
      if (permissionsGranted.isSuccess && !permissionsGranted.data!) {
        permissionsGranted = await _plugin.requestPermissions();
        return permissionsGranted.isSuccess && permissionsGranted.data!;
      }
      return permissionsGranted.isSuccess && permissionsGranted.data!;
    } catch (e) {
      debugPrint("Takvim izin hatası: $e");
      return false;
    }
  }

  static Future<String?> getDefaultCalendarId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedId = prefs.getString('default_calendar_id');

      final calendarsResult = await _plugin.retrieveCalendars();
      if (!calendarsResult.isSuccess ||
          calendarsResult.data == null ||
          calendarsResult.data!.isEmpty) {
        return null;
      }

      final writableCalendars =
          calendarsResult.data!.where((c) => c.isReadOnly == false).toList();
      if (writableCalendars.isEmpty) return null;

      if (savedId != null && writableCalendars.any((c) => c.id == savedId)) {
        return savedId;
      }

      final defaultCal = writableCalendars.firstWhere(
        (c) => c.isDefault == true,
        orElse: () => writableCalendars.first,
      );

      await prefs.setString('default_calendar_id', defaultCal.id!);
      return defaultCal.id;
    } catch (e) {
      debugPrint("Varsayılan takvim belirleme hatası: $e");
      return null;
    }
  }

  static Future<String?> addOrUpdateEvent({
    required String calendarId,
    String? existingEventId,
    required String title,
    required DateTime startTime,
    required int durationMinutes,
    String? description,
  }) async {
    try {
      final hasPerm = await requestPermissions();
      if (!hasPerm) return null;

      final startTz = tz.TZDateTime.from(startTime, tz.local);
      final endTz = startTz.add(Duration(minutes: durationMinutes));

      final event = Event(
        calendarId,
        eventId: existingEventId,
        title: title,
        start: startTz,
        end: endTz,
        description: description ?? 'WeeklyPulse Planı',
      );

      if (existingEventId != null && existingEventId.isNotEmpty) {
        final updateRes = await _plugin.createOrUpdateEvent(event);
        if (updateRes != null &&
            updateRes.isSuccess &&
            updateRes.data != null) {
          return updateRes.data;
        }
        // WP-007 FIX: Güncelleme başarısız olduğunda hemen yeni kayıt açıp duplicate yapma.
        debugPrint(
            "Takvim güncelleme başarısız oldu, mükerrer kaydı önlemek için iptal edildi: ${updateRes?.errors.map((e) => e.errorMessage).toList()}");
        return null;
      }

      final createRes = await _plugin.createOrUpdateEvent(event);
      if (createRes != null && createRes.isSuccess && createRes.data != null) {
        return createRes.data;
      }
      return null;
    } catch (e) {
      debugPrint("Takvim event işlem hatası: $e");
      return null;
    }
  }

  static Future<bool> deleteEvent(String calendarId, String eventId) async {
    try {
      final hasPerm = await requestPermissions();
      if (!hasPerm) return false;

      final res = await _plugin.deleteEvent(calendarId, eventId);
      return res.isSuccess && (res.data ?? false);
    } catch (e) {
      debugPrint("Takvim silme hatası: $e");
      return false;
    }
  }
}
