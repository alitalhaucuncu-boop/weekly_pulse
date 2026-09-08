import '../domain/models/task_item.dart';
import '../domain/models/planning_metrics.dart';
import '../core/constants.dart';

class PlanningEngine {
  static PlanningMetrics calculatePlanningMetricsForDay(
    List<TaskItem> tasks, {
    int dailyCapacityMinutes = 480,
  }) {
    if (tasks.isEmpty) {
      return PlanningMetrics(
        rawMinutes: 0,
        weightedMinutes: 0.0,
        capacityMinutes: dailyCapacityMinutes,
        capacityUsage: 0,
        taskCount: 0,
      );
    }

    int rawMin = 0;
    double weightedMin = 0.0;

    for (var t in tasks) {
      rawMin += t.durationMinutes;
      double multiplier = switch (t.priority) {
        'Kritik' => 2.0,
        'Yüksek' => 1.5,
        'Düşük' => 0.9,
        _ => 1.2,
      };
      weightedMin += (t.durationMinutes * multiplier);
    }

    int usage = ((weightedMin / dailyCapacityMinutes) * 100).round();

    return PlanningMetrics(
      rawMinutes: rawMin,
      weightedMinutes: weightedMin,
      capacityMinutes: dailyCapacityMinutes,
      capacityUsage: usage,
      taskCount: tasks.length,
    );
  }

  static bool hasTimeConflict(
      TaskItem currentTask, List<TaskItem> allDayTasks) {
    if (allDayTasks.length <= 1) return false;

    final cStart = currentTask.startDateTime;
    final cEnd = currentTask.endDateTime;

    for (var other in allDayTasks) {
      if (other.id == currentTask.id) continue;

      final oStart = other.startDateTime;
      final oEnd = other.endDateTime;

      if (cStart.isBefore(oEnd) && oStart.isBefore(cEnd)) {
        return true;
      }
    }
    return false;
  }

  static bool wouldConflictOnTargetDay(
    TaskItem candidate,
    DateTime targetDate,
    List<TaskItem> targetDayTasks, {
    int? customStartMinutes,
  }) {
    int startM = customStartMinutes ??
        (candidate.startDateTime.hour * 60 + candidate.startDateTime.minute);
    int candH = startM ~/ 60;
    int candM = startM % 60;

    final candStart = DateTime(
      targetDate.year,
      targetDate.month,
      targetDate.day,
      candH,
      candM,
    );
    final candEnd = candStart.add(Duration(minutes: candidate.durationMinutes));

    for (var other in targetDayTasks) {
      if (other.id == candidate.id) continue;
      final oStart = other.startDateTime;
      final oEnd = other.endDateTime;

      if (candStart.isBefore(oEnd) && oStart.isBefore(candEnd)) {
        return true;
      }
    }
    return false;
  }

  static Map<String, dynamic> generateWeeklyIntelligenceReport(
    List<TaskItem> allFetchedTasks,
  ) {
    int studentCount =
        allFetchedTasks.where((t) => t.taskMode == 'student').length;
    int proCount = allFetchedTasks.where((t) => t.taskMode == 'pro').length;

    int studentMinutes = 0;
    int proMinutes = 0;

    List<PlanningMetrics> dailyMetricsList = [];
    List<String> realConflicts = [];
    final Set<String> processedConflictPairs = {};

    for (var t in allFetchedTasks) {
      if (t.taskMode == 'student') studentMinutes += t.durationMinutes;
      if (t.taskMode == 'pro') proMinutes += t.durationMinutes;
    }

    for (int i = 0; i < 7; i++) {
      final dayTasks = allFetchedTasks.where((t) => t.dayIndex == i).toList();
      dailyMetricsList.add(calculatePlanningMetricsForDay(dayTasks));

      for (var j = 0; j < dayTasks.length; j++) {
        for (var k = j + 1; k < dayTasks.length; k++) {
          final tA = dayTasks[j];
          final tB = dayTasks[k];

          if (tA.startDateTime.isBefore(tB.endDateTime) &&
              tB.startDateTime.isBefore(tA.endDateTime)) {
            final pairKey = tA.id.compareTo(tB.id) < 0
                ? "${tA.id}_${tB.id}"
                : "${tB.id}_${tA.id}";

            if (!processedConflictPairs.contains(pairKey)) {
              processedConflictPairs.add(pairKey);
              final modeA = tA.taskMode == 'student' ? '🎓 Ders' : '💼 İş';
              final modeB = tB.taskMode == 'student' ? '🎓 Ders' : '💼 İş';
              realConflicts.add(
                "${fullWeekDays[i]}: $modeA '${tA.title}' (${tA.taskTime}) ile $modeB '${tB.title}' (${tB.taskTime}) saatleri çakışıyor.",
              );
            }
          }
        }
      }
    }

    int busiestDay = 0;
    int lightestDay = 0;
    double maxWeighted = 0.0;
    double minWeighted = 99999.0;

    for (int i = 0; i < 7; i++) {
      final m = dailyMetricsList[i];
      if (m.weightedMinutes > maxWeighted) {
        maxWeighted = m.weightedMinutes;
        busiestDay = i;
      }
      if (m.weightedMinutes < minWeighted) {
        minWeighted = m.weightedMinutes;
        lightestDay = i;
      }
    }

    List<String> recommendations = [];
    int totalCount = allFetchedTasks.length;

    if (totalCount == 0) {
      recommendations.add(
          "Bu haftan tamamen boş görünüyor. Yeni hedefler ekleyip verimli bir hafta planlayabilirsin! ☕");
    } else {
      double totalHours = (studentMinutes + proMinutes) / 60.0;
      recommendations.add(
          "⏱️ Toplam Yaşam Yükün: ${totalHours.toStringAsFixed(1)} saat (${(studentMinutes / 60.0).toStringAsFixed(1)} sa Ders + ${(proMinutes / 60.0).toStringAsFixed(1)} sa İş).");

      int busiestCapScore = dailyMetricsList[busiestDay].capacityUsage;
      if (busiestCapScore >= 75) {
        recommendations.add(
            "⚡ En yoğun günün ${fullWeekDays[busiestDay]} (%$busiestCapScore Kapasite Kullanımı, ${(dailyMetricsList[busiestDay].rawMinutes / 60).toStringAsFixed(1)} sa). 'Dengele' butonuyla yükü dağıtabilirsin.");
      }
      if (lightestDay != busiestDay &&
          dailyMetricsList[lightestDay].rawMinutes <= 60) {
        recommendations.add(
            "💡 ${fullWeekDays[lightestDay]} günü oldukça rahat (${dailyMetricsList[lightestDay].rawMinutes} dk). Görev kaydırmak için ideal zaman.");
      }
      if (recommendations.length <= 1) {
        recommendations.add(
            "✨ Haftalık çalışma ve ders yükün dengeli dağılmış. Harika bir hafta dileriz!");
      }
    }

    return {
      'total': totalCount,
      'student': studentCount,
      'pro': proCount,
      'studentHours': (studentMinutes / 60.0).toStringAsFixed(1),
      'proHours': (proMinutes / 60.0).toStringAsFixed(1),
      'busiestDay': fullWeekDays[busiestDay],
      'busiestMinutes': dailyMetricsList[busiestDay].rawMinutes,
      'lightestDay': fullWeekDays[lightestDay],
      'clashes': realConflicts,
      'recommendations': recommendations,
    };
  }
}
