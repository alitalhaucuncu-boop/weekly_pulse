class PlanningMetrics {
  final int rawMinutes;
  final double weightedMinutes;
  final int capacityMinutes;
  final int capacityUsage;
  final int taskCount;

  const PlanningMetrics({
    required this.rawMinutes,
    required this.weightedMinutes,
    required this.capacityMinutes,
    required this.capacityUsage,
    required this.taskCount,
  });
}
