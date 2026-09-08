import 'package:flutter_test/flutter_test.dart';
import 'package:weekly_pulse/domain/models/task_item.dart';
import 'package:weekly_pulse/domain/parsers/voice_duration_parser.dart';
import 'package:weekly_pulse/application/planning_engine.dart';

void main() {
  group('PlanningEngine & Parser Unit Tests', () {
    test('VoiceDurationParser Türkçe yazılı süreleri doğru ayrıştırmalı', () {
      final res1 = VoiceDurationParser.parse('yarın iki saat ders çalışacağım');
      expect(res1.durationMinutes, 120);

      final res2 = VoiceDurationParser.parse('toplantı yarım saat sürecek');
      expect(res2.durationMinutes, 30);

      final res3 = VoiceDurationParser.parse('45 dakika mola ver');
      expect(res3.durationMinutes, 45);
    });

    test('PlanningEngine kapasite ve doluluk oranını doğru hesaplamalı', () {
      final tasks = [
        TaskItem(
          id: '1',
          userId: 'u1',
          title: 'Ders 1',
          category: 'Akademik',
          dayIndex: 0,
          weekStartDate: '2026-08-17',
          scheduledDate: '2026-08-17',
          durationMinutes: 120,
        ),
        TaskItem(
          id: '2',
          userId: 'u1',
          title: 'Ders 2',
          category: 'Akademik',
          dayIndex: 0,
          weekStartDate: '2026-08-17',
          scheduledDate: '2026-08-17',
          durationMinutes: 60,
        ),
      ];

      final metrics = PlanningEngine.calculatePlanningMetricsForDay(tasks);
      expect(metrics.capacityUsage, greaterThan(0));
    });

    test('PlanningEngine çakışmaları tespit etmeli', () {
      final existingTasks = [
        TaskItem(
          id: '1',
          userId: 'u1',
          title: 'Toplantı 1',
          category: 'İş',
          dayIndex: 1,
          weekStartDate: '2026-08-17',
          scheduledDate: '2026-08-18',
          taskTime: '10:00',
          durationMinutes: 60,
        ),
      ];

      final conflictingTask = TaskItem(
        id: '2',
        userId: 'u1',
        title: 'Toplantı 2',
        category: 'İş',
        dayIndex: 1,
        weekStartDate: '2026-08-17',
        scheduledDate: '2026-08-18',
        taskTime: '10:30',
        durationMinutes: 60,
      );

      final targetDate = DateTime(2026, 8, 18);
      final wouldConflict = PlanningEngine.wouldConflictOnTargetDay(
        conflictingTask,
        targetDate,
        existingTasks,
      );

      expect(wouldConflict, true);
    });
  });
}
