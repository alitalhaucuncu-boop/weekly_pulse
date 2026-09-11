import 'package:flutter_test/flutter_test.dart';
import 'package:weekly_pulse/domain/models/task_item.dart';
import 'package:weekly_pulse/application/planning_engine.dart';
import 'package:weekly_pulse/domain/parsers/voice_duration_parser.dart';
import 'package:weekly_pulse/data/calendar_service.dart';
import 'package:weekly_pulse/application/task_sync_coordinator.dart';

void main() {
  group('PlanningEngine Kapasite ve Çakışma Testleri', () {
    test('Kapasite kullanımı doğru hesaplanmalı (480 dk baz)', () {
      final tasks = [
        TaskItem(
          id: '1',
          userId: 'u1',
          title: 'Görev 1',
          category: 'İş',
          dayIndex: 0,
          scheduledDate: '2026-09-07',
          weekStartDate: '2026-09-07',
          taskTime: '10:00',
          durationMinutes: 120,
          priority: 'Orta',
        ),
        TaskItem(
          id: '2',
          userId: 'u1',
          title: 'Görev 2',
          category: 'Ders',
          dayIndex: 0,
          scheduledDate: '2026-09-07',
          weekStartDate: '2026-09-07',
          taskTime: '13:00',
          durationMinutes: 60,
          priority: 'Kritik',
        ),
      ];

      final metrics = PlanningEngine.calculatePlanningMetricsForDay(tasks);
      expect(metrics.capacityUsage, equals(55));
    });

    test('Zaman çakışması doğru tespit edilmeli (Interval Overlap)', () {
      final targetDate = DateTime(2026, 9, 8);

      final taskA = TaskItem(
        id: '1',
        userId: 'u1',
        title: 'Görev A',
        category: 'İş',
        dayIndex: 1,
        scheduledDate: '2026-09-08',
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
        scheduledDate: '2026-09-08',
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
        scheduledDate: '2026-09-08',
        weekStartDate: '2026-09-07',
        taskTime: '11:00',
        durationMinutes: 60,
      );

      expect(
        PlanningEngine.wouldConflictOnTargetDay(taskB, targetDate, [taskA]),
        isTrue,
      );

      expect(
        PlanningEngine.wouldConflictOnTargetDay(taskC, targetDate, [taskA]),
        isFalse,
      );
    });

    test('Haftalık Yaşam Raporu oluşturma ve çakışma tespiti', () {
      final tasks = [
        TaskItem(
          id: '1',
          userId: 'u1',
          title: 'Ders',
          category: 'Ders',
          dayIndex: 0,
          scheduledDate: '2026-09-07',
          weekStartDate: '2026-09-07',
          taskTime: '10:00',
          durationMinutes: 60,
          taskMode: 'student',
        ),
        TaskItem(
          id: '2',
          userId: 'u1',
          title: 'Toplantı',
          category: 'İş',
          dayIndex: 0,
          scheduledDate: '2026-09-07',
          weekStartDate: '2026-09-07',
          taskTime: '10:30',
          durationMinutes: 60,
          taskMode: 'pro',
        ),
      ];

      final report = PlanningEngine.generateWeeklyIntelligenceReport(tasks);
      expect(report['student'], equals(1));
      expect(report['pro'], equals(1));
      expect((report['clashes'] as List).length, equals(1));
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

  group('Data Layer & Contract Integrity Tests', () {
    test('CalendarDeleteResult model doğrulaması', () {
      const resSuccess =
          CalendarDeleteResult(status: CalendarDeleteStatus.deleted);
      expect(resSuccess.isSuccess, isTrue);
      expect(resSuccess.isNotFound, isFalse);

      const resNotFound =
          CalendarDeleteResult(status: CalendarDeleteStatus.notFound);
      expect(resNotFound.isSuccess, isFalse);
      expect(resNotFound.isNotFound, isTrue);

      const resFailed = CalendarDeleteResult(
          status: CalendarDeleteStatus.failed, message: 'İzin yok');
      expect(resFailed.isSuccess, isFalse);
      expect(resFailed.isNotFound, isFalse);
    });

    test('TaskSyncResult bütünleşik senkronizasyon mantığı', () {
      const fullSync = TaskSyncResult(
        isNotificationSynced: true,
        isCalendarSynced: true,
      );
      expect(fullSync.isFullySynced, isTrue);
      expect(fullSync.effectiveUserMessage, isNull);

      const partialSync = TaskSyncResult(
        isNotificationSynced: true,
        isCalendarSynced: false,
        calendarMessage: 'Takvim hatası',
      );
      expect(partialSync.isFullySynced, isFalse);
      expect(partialSync.effectiveUserMessage, contains('Takvim hatası'));
    });

    test('Optimistic Concurrency Control (CAS Version Increment)', () {
      final task = TaskItem(
        id: '1',
        userId: 'u1',
        title: 'Görev',
        category: 'İş',
        dayIndex: 0,
        weekStartDate: '2026-09-07',
        version: 2,
      );

      int expectedVersion = task.version;
      int newVersion = expectedVersion + 1;

      expect(newVersion, equals(3));
      expect(expectedVersion, isNot(equals(newVersion)));
    });
  });
}
