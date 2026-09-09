import 'package:flutter_test/flutter_test.dart';
import 'package:weekly_pulse/domain/models/task_item.dart';
import 'package:weekly_pulse/application/planning_engine.dart';
import 'package:weekly_pulse/domain/parsers/voice_duration_parser.dart';

void main() {
  group('PlanningEngine Unit Tests', () {
    test('Kapasite kullanımı doğru hesaplanmalı (480 dk baz)', () {
      final tasks = [
        TaskItem(
          id: '1',
          userId: 'u1',
          title: 'Görev 1',
          category: 'İş',
          dayIndex: 0,
          weekStartDate: '2026-09-07',
          durationMinutes: 120,
          priority: 'Orta',
        ),
        TaskItem(
          id: '2',
          userId: 'u1',
          title: 'Görev 2',
          category: 'Ders',
          dayIndex: 0,
          weekStartDate: '2026-09-07',
          durationMinutes: 60,
          priority: 'Kritik',
        ),
      ];

      final metrics = PlanningEngine.calculatePlanningMetricsForDay(tasks);
      expect(metrics.capacityUsage, equals(55));
    });

    test('Zaman çakışması doğru tespit edilmeli (Interval Overlap)', () {
      final taskA = TaskItem(
        id: '1',
        userId: 'u1',
        title: 'Görev A',
        category: 'İş',
        dayIndex: 1,
        weekStartDate: '2026-09-07',
        taskTime: '10:00',
        durationMinutes: 60,
      );

      final taskB = TaskItem(
        id: '2',
        userId: 'u1',
        title: 'Görev B',
        category: 'İş',
        dayIndex: 1,
        weekStartDate: '2026-09-07',
        taskTime: '10:30',
        durationMinutes: 60,
      );

      final taskC = TaskItem(
        id: '3',
        userId: 'u1',
        title: 'Görev C',
        category: 'İş',
        dayIndex: 1,
        weekStartDate: '2026-09-07',
        taskTime: '11:00',
        durationMinutes: 60,
      );

      final targetDate = DateTime(2026, 9, 8);
      expect(
        PlanningEngine.wouldConflictOnTargetDay(taskB, targetDate, [taskA]),
        isTrue,
      );
      expect(
        PlanningEngine.wouldConflictOnTargetDay(taskC, targetDate, [taskA]),
        isFalse,
      );
    });
  });

  group('VoiceDurationParser Tests (RegExp & Boundaries)', () {
    test('Kelime sınırı ve süre ayrıştırma testi', () {
      final res1 = VoiceDurationParser.parse('2 saat ders çalışacağım');
      expect(res1.durationMinutes, equals(120));
      expect(res1.validationError, isNull);

      final res2 = VoiceDurationParser.parse('45 dakika mola ver');
      expect(res2.durationMinutes, equals(45));
      expect(res2.validationError, isNull);

      final res3 = VoiceDurationParser.parse('birlikte toplantı yapacağız');
      expect(res3.durationMinutes, equals(60));
    });

    test('15 - 480 dakika kural sınırları doğrulanmalı', () {
      final resMin = VoiceDurationParser.parse('10 dakika hızlı tekrar');
      expect(resMin.validationError, isNotNull);

      final resMax = VoiceDurationParser.parse('10 saat maraton');
      expect(resMax.validationError, isNotNull);
    });
  });
}
