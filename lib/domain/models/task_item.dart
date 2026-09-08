class TaskItem {
  String id;
  String userId;
  String title;
  String category;
  int dayIndex;
  String? scheduledDate;
  String? weekStartDate;
  String taskMode;
  String taskTime;
  int durationMinutes;
  String priority;
  DateTime? deadline;
  String reminderTime;
  bool isCompleted;
  String? calendarId;
  String? calendarEventId;
  int? notificationId;
  String syncStatus;
  String? syncWarning;
  String? syncErrorCode;
  DateTime? lastSyncedAt;
  int version;

  TaskItem({
    required this.id,
    required this.userId,
    required this.title,
    required this.category,
    required this.dayIndex,
    this.scheduledDate,
    this.weekStartDate,
    this.taskMode = 'student',
    this.taskTime = '10:00',
    this.durationMinutes = 60,
    this.priority = 'Orta',
    this.deadline,
    this.reminderTime = '1 Saat Önce',
    this.isCompleted = false,
    this.calendarId,
    this.calendarEventId,
    this.notificationId,
    this.syncStatus = 'pending',
    this.syncWarning,
    this.syncErrorCode,
    this.lastSyncedAt,
    this.version = 1,
  });

  DateTime get startDateTime {
    final baseDate = DateTime.tryParse(scheduledDate ?? '') ?? DateTime.now();
    int hour = 10, minute = 0;
    try {
      final parts = taskTime.split(':');
      if (parts.length == 2) {
        hour = int.parse(parts[0]);
        minute = int.parse(parts[1]);
      }
    } catch (_) {}
    return DateTime(baseDate.year, baseDate.month, baseDate.day, hour, minute);
  }

  DateTime get endDateTime =>
      startDateTime.add(Duration(minutes: durationMinutes));

  // TaskCard için gerekli deadline ihlal kontrolü
  bool get isDeadlineViolated {
    if (deadline == null) return false;
    return endDateTime.isAfter(deadline!);
  }

  factory TaskItem.fromJson(Map<String, dynamic> json) {
    return TaskItem(
      id: json['id']?.toString() ?? '',
      userId: json['user_id']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      category: json['category']?.toString() ?? '',
      dayIndex: json['day_index'] is int
          ? json['day_index']
          : int.tryParse(json['day_index']?.toString() ?? '0') ?? 0,
      scheduledDate: json['scheduled_date']?.toString(),
      weekStartDate: json['week_start_date']?.toString(),
      taskMode: json['task_mode']?.toString() ?? 'student',
      taskTime: json['task_time']?.toString() ?? '10:00',
      durationMinutes: json['duration_minutes'] is int
          ? json['duration_minutes']
          : int.tryParse(json['duration_minutes']?.toString() ?? '60') ?? 60,
      priority: json['priority']?.toString() ?? 'Orta',
      deadline: json['deadline'] != null
          ? DateTime.tryParse(json['deadline'].toString())
          : null,
      reminderTime: json['reminder_time']?.toString() ?? '1 Saat Önce',
      isCompleted: json['is_completed'] == true,
      calendarId: json['calendar_id']?.toString(),
      calendarEventId: json['calendar_event_id']?.toString(),
      notificationId: json['notification_id'] is int
          ? json['notification_id']
          : int.tryParse(json['notification_id']?.toString() ?? ''),
      syncStatus: json['sync_status']?.toString() ?? 'pending',
      syncWarning: json['sync_warning']?.toString(),
      syncErrorCode: json['sync_error_code']?.toString(),
      lastSyncedAt: json['last_synced_at'] != null
          ? DateTime.tryParse(json['last_synced_at'].toString())
          : null,
      version: json['version'] is int
          ? json['version']
          : int.tryParse(json['version']?.toString() ?? '1') ?? 1,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'user_id': userId,
      'title': title,
      'category': category,
      'day_index': dayIndex,
      'scheduled_date': scheduledDate,
      'week_start_date': weekStartDate,
      'task_mode': taskMode,
      'task_time': taskTime,
      'duration_minutes': durationMinutes,
      'priority': priority,
      'deadline': deadline?.toIso8601String(),
      'reminder_time': reminderTime,
      'is_completed': isCompleted,
      'calendar_id': calendarId,
      'calendar_event_id': calendarEventId,
      'notification_id': notificationId,
      'sync_status': syncStatus,
      'sync_warning': syncWarning,
      'sync_error_code': syncErrorCode,
      'last_synced_at': lastSyncedAt?.toIso8601String(),
      'version': version,
    };
  }
}
