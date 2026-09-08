class DurationParseResult {
  final int durationMinutes;
  final String cleanedText;
  final String? validationError;

  const DurationParseResult({
    required this.durationMinutes,
    required this.cleanedText,
    this.validationError,
  });
}

class VoiceTaskParseResult {
  final String title;
  final int dayIndex;
  final String scheduledDate;
  final String taskTime;
  final int durationMinutes;
  final String priority;
  final DateTime? deadline;
  final String reminderTime;
  final String? validationError;

  const VoiceTaskParseResult({
    required this.title,
    required this.dayIndex,
    required this.scheduledDate,
    required this.taskTime,
    required this.durationMinutes,
    required this.priority,
    this.deadline,
    this.reminderTime = '1 Saat Önce',
    this.validationError,
  });
}
