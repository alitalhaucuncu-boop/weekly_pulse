import 'package:flutter/material.dart';
import '../../domain/models/task_item.dart';
import '../../application/planning_engine.dart';

class TaskCard extends StatelessWidget {
  final TaskItem task;
  final Color primaryColor;
  final List<TaskItem> allDayTasks;
  final Function(bool) onStatusChanged;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback? onRetrySync;

  const TaskCard({
    super.key,
    required this.task,
    required this.primaryColor,
    required this.allDayTasks,
    required this.onStatusChanged,
    required this.onEdit,
    required this.onDelete,
    this.onRetrySync,
  });

  @override
  Widget build(BuildContext context) {
    Color priorityColor = Colors.grey;
    if (task.priority == 'Kritik') {
      priorityColor = Colors.redAccent;
    } else if (task.priority == 'Yüksek') {
      priorityColor = Colors.orange;
    } else if (task.priority == 'Düşük') {
      priorityColor = Colors.blueGrey;
    }

    bool hasConflict = PlanningEngine.hasTimeConflict(task, allDayTasks);
    bool isSyncIssue =
        task.syncStatus == 'partial' || task.syncStatus == 'failed';

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: hasConflict ? Colors.redAccent : Colors.grey.shade300,
          width: hasConflict ? 1.5 : 1,
        ),
      ),
      child: ListTile(
        leading: Checkbox(
          value: task.isCompleted,
          activeColor: primaryColor,
          onChanged: (val) {
            if (val != null) onStatusChanged(val);
          },
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                task.title,
                style: TextStyle(
                  decoration:
                      task.isCompleted ? TextDecoration.lineThrough : null,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (hasConflict) ...[
              Container(
                margin: const EdgeInsets.only(right: 6),
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.redAccent,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text(
                  '⚠️ Çakışma',
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
            if (isSyncIssue) ...[
              GestureDetector(
                onTap: onRetrySync,
                child: Container(
                  margin: const EdgeInsets.only(right: 6),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                  decoration: BoxDecoration(
                    color: task.syncStatus == 'partial'
                        ? Colors.orange
                        : Colors.red,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        task.syncStatus == 'partial'
                            ? Icons.sync_problem
                            : Icons.sync_disabled,
                        color: Colors.white,
                        size: 10,
                      ),
                      const SizedBox(width: 3),
                      Text(
                        task.syncStatus == 'partial'
                            ? 'Kısmi Eşitlendi ⚡'
                            : 'Eşitlenemedi ⚡',
                        style: const TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: priorityColor.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                task.priority,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: priorityColor,
                ),
              ),
            ),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 2),
            Row(
              children: [
                const Icon(Icons.access_time,
                    size: 13, color: Colors.deepPurple),
                const SizedBox(width: 4),
                Text(
                  "${task.taskTime} (${task.durationMinutes} dk)",
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: Colors.deepPurple,
                  ),
                ),
                const SizedBox(width: 10),
                const Icon(Icons.notifications_active_outlined,
                    size: 13, color: Colors.orange),
                const SizedBox(width: 4),
                Text(
                  task.reminderTime,
                  style: const TextStyle(fontSize: 11, color: Colors.orange),
                ),
              ],
            ),
            if (task.deadline != null) ...[
              const SizedBox(height: 2),
              Row(
                children: [
                  Icon(
                    task.isDeadlineViolated
                        ? Icons.error_outline
                        : Icons.flag_outlined,
                    size: 12,
                    color: task.isDeadlineViolated
                        ? Colors.deepOrange
                        : Colors.redAccent,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    "Deadline: ${task.deadline!.day}/${task.deadline!.month}/${task.deadline!.year} ${task.deadline!.hour.toString().padLeft(2, '0')}:${task.deadline!.minute.toString().padLeft(2, '0')}",
                    style: TextStyle(
                      fontSize: 10,
                      color: task.isDeadlineViolated
                          ? Colors.deepOrange
                          : Colors.redAccent,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Chip(
              label: Text(task.category, style: const TextStyle(fontSize: 10)),
            ),
            IconButton(
              icon: const Icon(Icons.edit_outlined,
                  color: Colors.blueGrey, size: 20),
              onPressed: onEdit,
              tooltip: 'Planı Düzenle',
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline,
                  color: Colors.redAccent, size: 20),
              onPressed: onDelete,
              tooltip: 'Planı Sil',
            ),
          ],
        ),
      ),
    );
  }
}
