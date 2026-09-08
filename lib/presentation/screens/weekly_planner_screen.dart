import 'dart:math';
import 'package:flutter/material.dart';
import 'package:confetti/confetti.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/constants.dart';
import '../../domain/models/task_item.dart';
import '../../domain/models/voice_models.dart';
import '../../domain/parsers/voice_duration_parser.dart';
import '../../data/notification_service.dart';
import '../../data/calendar_service.dart';
import '../../application/planning_engine.dart';
import '../../application/recovery_engine.dart';
import '../../application/task_sync_coordinator.dart';
import '../widgets/task_card.dart';
import 'auth_screen.dart';

enum ViewMode { daily, weekly, monthly }

enum TaskMoveStatus { success, partial, failed, busy }

class TaskMoveResult {
  final TaskMoveStatus status;
  final String? message;

  const TaskMoveResult({required this.status, this.message});

  bool get isSuccess => status == TaskMoveStatus.success;
  bool get isBusy => status == TaskMoveStatus.busy;
}

Function(String taskId)? onGlobalNotificationFocus;
String? globalPendingNotificationTaskId;

class WeeklyPlannerScreen extends StatefulWidget {
  final bool isDark;
  final VoidCallback onThemeToggle;

  const WeeklyPlannerScreen({
    super.key,
    required this.isDark,
    required this.onThemeToggle,
  });

  @override
  State<WeeklyPlannerScreen> createState() => _WeeklyPlannerScreenState();
}

class _WeeklyPlannerScreenState extends State<WeeklyPlannerScreen> {
  String activeMode = 'student';
  ViewMode currentViewMode = ViewMode.daily;
  int selectedDayIndex = 0;
  DateTime focusedCalendarDay = DateTime.now();
  DateTime selectedCalendarDay = DateTime.now();

  bool _isLoadingTasks = true;
  final Set<String> _movingTaskIds = <String>{};

  late DateTime currentWeekMonday;
  late ConfettiController _confettiController;

  final SpeechToText _speechToText = SpeechToText();
  bool _isListening = false;

  int voiceUsage = 0;
  int aiUsage = 0;
  bool isUserPremium = false;
  String userTierName = 'Free';
  String userPlanId = 'free';

  List<TaskItem> allFetchedTasks = [];
  List<TaskItem> allMonthFetchedTasks = [];

  String _formatDateToKey(DateTime date) {
    return "${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}";
  }

  void _changeWeek(int weekOffset) {
    setState(() {
      currentWeekMonday = currentWeekMonday.add(Duration(days: weekOffset * 7));
    });
    _fetchTasks();
  }

  void _resetToCurrentWeek() {
    DateTime now = DateTime.now();
    setState(() {
      currentWeekMonday = DateTime(now.year, now.month, now.day)
          .subtract(Duration(days: now.weekday - 1));
      selectedDayIndex = now.weekday - 1;
      focusedCalendarDay = now;
      selectedCalendarDay = DateTime(now.year, now.month, now.day);
    });
    _fetchTasks();
    _fetchAllTasksForMonth(now);
  }

  Future<bool> focusOnTaskById(String taskId) async {
    final user = supabase.auth.currentUser;
    if (user == null) {
      return false;
    }

    TaskItem? targetTask = allFetchedTasks.firstWhere((t) => t.id == taskId,
        orElse: () => allMonthFetchedTasks.firstWhere((t) => t.id == taskId,
            orElse: () => TaskItem(
                id: '',
                userId: '',
                title: '',
                category: '',
                dayIndex: 0,
                weekStartDate: '')));

    if (targetTask.id.isEmpty) {
      try {
        final res = await supabase
            .from('weekly_tasks')
            .select()
            .eq('id', taskId)
            .eq('user_id', user.id)
            .maybeSingle();
        if (res != null) {
          targetTask = TaskItem.fromJson(res);
        }
      } catch (_) {
        return false;
      }
    }

    if (targetTask.id.isNotEmpty && targetTask.scheduledDate != null) {
      final taskDate = DateTime.tryParse(targetTask.scheduledDate!);
      if (taskDate != null && mounted) {
        setState(() {
          activeMode = targetTask!.taskMode;
          currentViewMode = ViewMode.daily;
          selectedCalendarDay = taskDate;
          focusedCalendarDay = taskDate;
          currentWeekMonday =
              taskDate.subtract(Duration(days: taskDate.weekday - 1));
          selectedDayIndex = taskDate.weekday - 1;
        });
        _fetchTasks();
        return true;
      }
    }
    return false;
  }

  @override
  void initState() {
    super.initState();
    _confettiController =
        ConfettiController(duration: const Duration(seconds: 4));
    DateTime now = DateTime.now();
    currentWeekMonday = DateTime(now.year, now.month, now.day)
        .subtract(Duration(days: now.weekday - 1));

    selectedDayIndex = now.weekday - 1;
    selectedCalendarDay = DateTime(now.year, now.month, now.day);

    onGlobalNotificationFocus = (taskId) {
      if (mounted) {
        focusOnTaskById(taskId);
      }
    };

    _loadPreferences();
    _loadUserProfileAndResetWeeklyQuotas();
    _fetchTasks();
    _fetchAllTasksForMonth(focusedCalendarDay);

    TaskSyncCoordinator.reconcilePendingAndFailedTasks().then((reconciled) {
      if (reconciled > 0 && mounted) {
        _fetchTasks();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('⚡ $reconciled bekleyen görev eşitlendi.'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (globalPendingNotificationTaskId != null) {
        final success = await focusOnTaskById(globalPendingNotificationTaskId!);
        if (success) {
          globalPendingNotificationTaskId = null;
        }
      }
    });
  }

  @override
  void dispose() {
    onGlobalNotificationFocus = null;
    _confettiController.dispose();
    super.dispose();
  }

  void _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    final savedMode = prefs.getString('active_mode');
    if (savedMode != null && mounted) {
      setState(() {
        activeMode = savedMode;
      });
    }
  }

  void _switchMode(String mode) async {
    setState(() {
      activeMode = mode;
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('active_mode', mode);
  }

  Future<void> _loadUserProfileAndResetWeeklyQuotas() async {
    final user = supabase.auth.currentUser;
    if (user == null) return;

    try {
      final dynamic syncRes = await supabase.rpc('sync_my_profile_status');

      if (syncRes is Map && syncRes['success'] == true && mounted) {
        setState(() {
          isUserPremium = syncRes['is_premium'] ?? false;
          userTierName = syncRes['tier_name'] ?? 'Free';
          userPlanId = syncRes['plan_id'] ?? 'free';
          voiceUsage = syncRes['voice_usage'] ?? 0;
          aiUsage = syncRes['ai_usage'] ?? 0;
        });

        if (isUserPremium) {
          NotificationService.scheduleWeeklyReportNotification(
              userTierName: userTierName);
        }
      }
    } catch (e) {
      debugPrint("Profil Senkronizasyon Hatası: $e");
    }
  }

  void _showSmartRebalanceDialog() {
    final activeTasks = _getFilteredTasksForCurrentMode();

    int busiestDay = -1;
    int maxScore = 0;
    int lightestDay = -1;
    int minScore = 999;

    for (int i = 0; i < 7; i++) {
      final dTasks = activeTasks[i] ?? [];
      final metrics = PlanningEngine.calculatePlanningMetricsForDay(dTasks);
      if (metrics.capacityUsage > maxScore) {
        maxScore = metrics.capacityUsage;
        busiestDay = i;
      }
      if (metrics.capacityUsage < minScore) {
        minScore = metrics.capacityUsage;
        lightestDay = i;
      }
    }

    if (busiestDay == -1 || maxScore < 60 || lightestDay == busiestDay) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✨ Haftalık planın zaten dengeli görünüyor!'),
          backgroundColor: Colors.green,
        ),
      );
      return;
    }

    final busiestTasks = activeTasks[busiestDay] ?? [];
    final targetDayTasks = activeTasks[lightestDay] ?? [];
    final lightestDayDate = currentWeekMonday.add(Duration(days: lightestDay));

    bool isTaskMoveFeasible(TaskItem t) {
      final targetEnd = DateTime(
        lightestDayDate.year,
        lightestDayDate.month,
        lightestDayDate.day,
        t.startDateTime.hour,
        t.startDateTime.minute,
      ).add(Duration(minutes: t.durationMinutes));

      bool deadlineOk = (t.deadline == null || !targetEnd.isAfter(t.deadline!));
      bool noConflict = !PlanningEngine.wouldConflictOnTargetDay(
          t, lightestDayDate, targetDayTasks);
      return deadlineOk && noConflict;
    }

    TaskItem? candidateTask;
    for (var t in busiestTasks) {
      if (!t.isCompleted && (t.priority == 'Düşük' || t.priority == 'Orta')) {
        if (isTaskMoveFeasible(t)) {
          candidateTask = t;
          break;
        }
      }
    }

    if (candidateTask == null) {
      for (var t in busiestTasks) {
        if (!t.isCompleted && isTaskMoveFeasible(t)) {
          candidateTask = t;
          break;
        }
      }
    }

    if (candidateTask == null) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text(
                'Teslim tarihine ve hedef gün saatlerine uygun taşınabilir görev bulunamadı.')),
      );
      return;
    }

    final targetTask = candidateTask;

    showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          title: const Row(
            children: [
              Icon(Icons.balance, color: Colors.deepPurple, size: 26),
              SizedBox(width: 8),
              Text('Akıllı Hafta Dengeleyici ⚖️',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${fullWeekDays[busiestDay]} günü çok yoğun (%$maxScore Yük).',
                style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.redAccent,
                    fontSize: 13),
              ),
              const SizedBox(height: 8),
              Text(
                '💡 Öneri: "${targetTask.title}" (${targetTask.taskTime}) görevini ${fullWeekDays[lightestDay]} gününe taşımak ister misiniz?',
                style: const TextStyle(fontSize: 13, height: 1.3),
              ),
              if (targetTask.deadline != null) ...[
                const SizedBox(height: 6),
                Text(
                  '🎯 Son Teslim (Deadline): ${targetTask.deadline!.day}/${targetTask.deadline!.month}/${targetTask.deadline!.year} ${targetTask.deadline!.hour.toString().padLeft(2, '0')}:${targetTask.deadline!.minute.toString().padLeft(2, '0')}',
                  style: const TextStyle(
                      fontSize: 11,
                      color: Colors.blueGrey,
                      fontWeight: FontWeight.w600),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Vazgeç'),
            ),
            ElevatedButton(
              style:
                  ElevatedButton.styleFrom(backgroundColor: Colors.deepPurple),
              onPressed: () async {
                Navigator.pop(dialogContext);
                final scaffoldMessenger = ScaffoldMessenger.of(context);
                final result = await _moveTaskToNewDay(targetTask, lightestDay);
                if (!mounted) {
                  return;
                }

                if (result.isSuccess) {
                  _confettiController.play();
                  scaffoldMessenger.showSnackBar(
                    SnackBar(
                      content: Text(
                          '🚀 "${targetTask.title}" başarıyla ${fullWeekDays[lightestDay]} gününe taşındı!'),
                      backgroundColor: Colors.deepPurple,
                    ),
                  );
                } else if (result.isBusy) {
                  scaffoldMessenger.showSnackBar(
                    const SnackBar(
                      content:
                          Text('⏳ Görev taşıma işlemi zaten devam ediyor.'),
                      backgroundColor: Colors.blueGrey,
                    ),
                  );
                } else {
                  scaffoldMessenger.showSnackBar(
                    SnackBar(
                      content: Text(result.message ??
                          '⚠️ Görev taşındı fakat tam senkronize edilemedi.'),
                      backgroundColor: Colors.orange,
                    ),
                  );
                }
              },
              child: const Text('Onayla ve Dengele 🚀',
                  style: TextStyle(
                      color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
    );
  }

  void _showProfileDialog() {
    final user = supabase.auth.currentUser;
    final email = user?.email ?? 'Kullanıcı';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (modalContext) {
        return StatefulBuilder(
          builder: (context, setProfileState) {
            return Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const CircleAvatar(
                        radius: 28,
                        backgroundColor: Color(0xFF7895CB),
                        child:
                            Icon(Icons.person, color: Colors.white, size: 32),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(email,
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold, fontSize: 16)),
                            const SizedBox(height: 4),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: isUserPremium
                                    ? Colors.amber.shade700
                                    : Colors.grey.shade400,
                              ),
                              child: Text(
                                isUserPremium
                                    ? '👑 $userTierName Üyesi ($userPlanId)'
                                    : 'Ücretsiz Plan (Free)',
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  const Divider(),
                  const SizedBox(height: 8),
                  const Text('📊 Haftalık Kota Durumu',
                      style:
                          TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: widget.isDark
                          ? Colors.grey.shade800
                          : Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('🎙️ Sesli Komut Kullanımı:'),
                            Text(
                              isUserPremium
                                  ? 'Sınırsız ♾️'
                                  : '$voiceUsage / 3 Hak',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: isUserPremium
                                    ? Colors.green
                                    : Colors.orange,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('🤖 Akıllı Analiz Raporu:'),
                            Text(
                              isUserPremium
                                  ? 'Sınırsız ♾️'
                                  : '$aiUsage / 1 Hak',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: isUserPremium
                                    ? Colors.green
                                    : Colors.orange,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  if (isUserPremium) ...[
                    SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.redAccent,
                          side: const BorderSide(
                              color: Colors.redAccent, width: 1.5),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                        ),
                        icon: const Icon(Icons.cancel_outlined),
                        label: const Text('Üyeliğimi İptal Et (Demo)',
                            style: TextStyle(fontWeight: FontWeight.bold)),
                        onPressed: () {
                          Navigator.pop(modalContext);
                          _confirmCancelSubscription();
                        },
                      ),
                    ),
                  ] else ...[
                    SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.amber.shade800,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                        ),
                        icon: const Icon(Icons.workspace_premium,
                            color: Colors.white),
                        label: const Text('Elit Kulübe Katıl 👑',
                            style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold)),
                        onPressed: () {
                          Navigator.pop(modalContext);
                          _showPricingModal();
                        },
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: TextButton.icon(
                      style: TextButton.styleFrom(foregroundColor: Colors.grey),
                      icon: const Icon(Icons.logout),
                      label: const Text('Hesaptan Çıkış Yap'),
                      onPressed: () async {
                        final navigator = Navigator.of(context);
                        await supabase.auth.signOut();
                        if (!mounted) {
                          return;
                        }
                        navigator.pushReplacement(
                          MaterialPageRoute(
                            builder: (_) => AuthScreen(
                              onThemeToggle: widget.onThemeToggle,
                              isDark: widget.isDark,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _confirmCancelSubscription() {
    showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Text('Üyeliği İptal Et ⚠️',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          content: const Text(
            'Aboneliğinizi iptal etmek istediğinize emin misiniz?',
            style: TextStyle(fontSize: 13, color: Colors.grey),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Vazgeç'),
            ),
            ElevatedButton(
              style:
                  ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
              onPressed: () async {
                final scaffoldMessenger = ScaffoldMessenger.of(context);
                try {
                  final res = await supabase.rpc('cancel_my_subscription');
                  final bool ok = res is Map && res['success'] == true;

                  if (ok) {
                    try {
                      await NotificationService.cancelNotification(99999);
                    } catch (_) {}

                    if (mounted) {
                      setState(() {
                        isUserPremium = false;
                        userTierName = 'Free';
                        userPlanId = 'free';
                      });
                      Navigator.pop(dialogContext);
                      scaffoldMessenger.showSnackBar(
                        const SnackBar(
                            content: Text('Aboneliğiniz iptal edildi.')),
                      );
                    }
                  } else {
                    if (mounted) {
                      Navigator.pop(dialogContext);
                      scaffoldMessenger.showSnackBar(
                        const SnackBar(
                            content: Text('İptal işlemi gerçekleştirilemedi.')),
                      );
                    }
                  }
                } catch (e) {
                  debugPrint("İptal Hatası: $e");
                  if (mounted) {
                    Navigator.pop(dialogContext);
                    scaffoldMessenger.showSnackBar(
                      const SnackBar(content: Text('Bağlantı hatası oluştu.')),
                    );
                  }
                }
              },
              child: const Text('Evet, İptal Et',
                  style: TextStyle(
                      color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
    );
  }

  void _showAIAnalysisModal() async {
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    final user = supabase.auth.currentUser;
    if (user == null) return;

    final String requestId =
        "ai_${user.id}_${DateTime.now().millisecondsSinceEpoch}";

    try {
      final dynamic quotaRes = await supabase.rpc(
        'consume_ai_quota',
        params: {
          'p_request_id': requestId,
        },
      );

      if (quotaRes is! Map || quotaRes['success'] != true) {
        final message = (quotaRes is Map) ? quotaRes['message'] : null;
        if (!mounted) {
          return;
        }
        _showLimitExceededDialog(
          title: 'Haftalık Akıllı Analiz Hakkın Doldu! 🤖',
          message: message ??
              'Ücretsiz sürümde haftada 1 kez Akıllı Analiz alabilirsin.',
        );
        return;
      }
      if (mounted) {
        setState(() {
          aiUsage = quotaRes['ai_usage'] ?? aiUsage;
          isUserPremium = quotaRes['is_premium'] ?? isUserPremium;
        });
      }
    } catch (e) {
      debugPrint("AI Quota RPC Error: $e");
      if (!isUserPremium) {
        if (mounted) {
          scaffoldMessenger.showSnackBar(
            const SnackBar(content: Text('Kota doğrulanamadı.')),
          );
        }
        return;
      }
    }

    final report =
        PlanningEngine.generateWeeklyIntelligenceReport(allFetchedTasks);

    if (!mounted) {
      return;
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (modalContext) {
        return Container(
          padding: const EdgeInsets.all(24.0),
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.85,
          ),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.auto_awesome,
                        color: Colors.amber, size: 30),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        isUserPremium
                            ? '👑 Weekly Intelligence VIP Raporu'
                            : '🤖 WeeklyPulse Bütünsel Yük Analizi',
                        style: const TextStyle(
                            fontSize: 17, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color:
                              const Color(0xFF4A55A2).withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('🎓 Akademik / Ders',
                                style: TextStyle(
                                    fontSize: 11, color: Colors.grey)),
                            const SizedBox(height: 4),
                            Text(
                                '${report['student']} Plan (${report['studentHours']} sa)',
                                style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xFF4A55A2))),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color:
                              const Color(0xFF1E293B).withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('💼 Profesyonel / İş',
                                style: TextStyle(
                                    fontSize: 11, color: Colors.grey)),
                            const SizedBox(height: 4),
                            Text(
                                '${report['pro']} Görev (${report['proHours']} sa)',
                                style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xFF1E293B))),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                if ((report['clashes'] as List).isNotEmpty) ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.redAccent.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                          color: Colors.redAccent.withValues(alpha: 0.4)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Row(
                          children: [
                            Icon(Icons.warning_amber_rounded,
                                color: Colors.redAccent, size: 18),
                            SizedBox(width: 6),
                            Text('Haftalık Gerçek Zaman Çakışmaları:',
                                style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 12,
                                    color: Colors.redAccent)),
                          ],
                        ),
                        const SizedBox(height: 6),
                        ...(report['clashes'] as List<String>)
                            .map((c) => Padding(
                                  padding: const EdgeInsets.only(bottom: 4.0),
                                  child: Text("• $c",
                                      style: const TextStyle(fontSize: 11)),
                                )),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                ],
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: widget.isDark
                        ? Colors.grey.shade900
                        : Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                        color: const Color(0xFF7895CB).withValues(alpha: 0.3)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.insights,
                              size: 18, color: Color(0xFF7895CB)),
                          SizedBox(width: 6),
                          Text('Haftalık Zeka Analiz Tavsiyeleri:',
                              style: TextStyle(
                                  fontWeight: FontWeight.bold, fontSize: 13)),
                        ],
                      ),
                      const SizedBox(height: 8),
                      ...(report['recommendations'] as List<String>)
                          .map((rec) => Padding(
                                padding: const EdgeInsets.only(bottom: 6.0),
                                child: Text(rec,
                                    style: const TextStyle(
                                        fontSize: 12, height: 1.3)),
                              )),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF7895CB)),
                    onPressed: () => Navigator.pop(modalContext),
                    child: const Text('Anladım, Harika! 👍',
                        style: TextStyle(
                            color: Colors.white, fontWeight: FontWeight.bold)),
                  ),
                )
              ],
            ),
          ),
        );
      },
    );
  }

  void _showLimitExceededDialog(
      {required String title, required String message}) {
    showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          title: Text(title,
              textAlign: TextAlign.center,
              style:
                  const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          content: Text(message,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: Colors.grey)),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('İptal')),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.amber.shade800),
              onPressed: () {
                Navigator.pop(dialogContext);
                _showPricingModal();
              },
              child: const Text('Kulübe Katıl 👑',
                  style: TextStyle(
                      color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
    );
  }

  Widget _buildPricingCard({
    required String title,
    required String monthlyPrice,
    required String yearlyPrice,
    required String tierCode,
    required String monthlyPlanId,
    required String yearlyPlanId,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        border: Border.all(color: color, width: 2),
        borderRadius: BorderRadius.circular(16),
        color: color.withValues(alpha: 0.05),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: TextStyle(
                  fontWeight: FontWeight.bold, fontSize: 15, color: color)),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(monthlyPrice,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 12)),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                    backgroundColor: color, minimumSize: const Size(80, 30)),
                onPressed: () =>
                    _handleStorePurchase(tierCode, monthlyPlanId, false),
                child: const Text('Katıl (Demo)',
                    style: TextStyle(color: Colors.white, fontSize: 11)),
              )
            ],
          ),
          const Divider(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(yearlyPrice,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 11,
                      color: Colors.green)),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    minimumSize: const Size(80, 30)),
                onPressed: () =>
                    _handleStorePurchase(tierCode, yearlyPlanId, true),
                child: const Text('Yıllık (Demo)',
                    style: TextStyle(color: Colors.white, fontSize: 11)),
              )
            ],
          ),
        ],
      ),
    );
  }

  void _showPricingModal() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (modalContext) {
        return Container(
          padding: const EdgeInsets.all(24),
          height: MediaQuery.of(context).size.height * 0.85,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Center(
                  child: Text('WeeklyPulse Elit Kulüp 👑',
                      style: TextStyle(
                          fontSize: 22, fontWeight: FontWeight.bold))),
              const SizedBox(height: 20),
              _buildPricingCard(
                title: '🎓 SCHOLAR (Öğrenci Kulübü)',
                monthlyPrice: '99.99 TL / ay',
                yearlyPrice: '999.99 TL / yıl (2 Ay Bedava)',
                tierCode: 'Scholar 🎓',
                monthlyPlanId: 'scholar_monthly',
                yearlyPlanId: 'scholar_yearly',
                color: const Color(0xFF4A55A2),
              ),
              const SizedBox(height: 12),
              _buildPricingCard(
                title: '💼 EXECUTIVE (İş Kulübü)',
                monthlyPrice: '99.99 TL / ay',
                yearlyPrice: '999.99 TL / yıl (2 Ay Bedava)',
                tierCode: 'Executive 👑',
                monthlyPlanId: 'executive_monthly',
                yearlyPlanId: 'executive_yearly',
                color: const Color(0xFF1E293B),
              ),
            ],
          ),
        );
      },
    );
  }

  void _handleStorePurchase(String tierName, String planId, bool isYearly) {
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content:
            Text('👑 $tierName üyeliği mağaza sürümünde aktif edilecektir.'),
        backgroundColor: const Color(0xFF7895CB),
      ),
    );
  }

  VoiceTaskParseResult _parseVoiceCommandToTask(String speechText) {
    String lower = speechText.toLowerCase();

    DateTime now = DateTime.now();
    int detectedDayIndex = (selectedDayIndex < 0 || selectedDayIndex >= 7)
        ? (now.weekday - 1)
        : selectedDayIndex;

    DateTime targetDate = now;

    if (RegExp(r'\bcumartesi\b').hasMatch(lower)) {
      detectedDayIndex = 5;
      targetDate = currentWeekMonday.add(const Duration(days: 5));
    } else if (RegExp(r'\bpazartesi\b').hasMatch(lower)) {
      detectedDayIndex = 0;
      targetDate = currentWeekMonday.add(const Duration(days: 0));
    } else if (RegExp(r'\bçarşamba\b').hasMatch(lower)) {
      detectedDayIndex = 2;
      targetDate = currentWeekMonday.add(const Duration(days: 2));
    } else if (RegExp(r'\bperşembe\b').hasMatch(lower)) {
      detectedDayIndex = 3;
      targetDate = currentWeekMonday.add(const Duration(days: 3));
    } else if (RegExp(r'\bcuma\b').hasMatch(lower)) {
      detectedDayIndex = 4;
      targetDate = currentWeekMonday.add(const Duration(days: 4));
    } else if (RegExp(r'\bsalı\b').hasMatch(lower)) {
      detectedDayIndex = 1;
      targetDate = currentWeekMonday.add(const Duration(days: 1));
    } else if (RegExp(r'\bpazar\b').hasMatch(lower)) {
      detectedDayIndex = 6;
      targetDate = currentWeekMonday.add(const Duration(days: 6));
    } else if (RegExp(r'\byarın\b').hasMatch(lower)) {
      targetDate = now.add(const Duration(days: 1));
      detectedDayIndex = targetDate.weekday - 1;
    } else if (RegExp(r'\bbugün\b').hasMatch(lower)) {
      targetDate = now;
      detectedDayIndex = now.weekday - 1;
    } else {
      targetDate = currentWeekMonday.add(Duration(days: detectedDayIndex));
    }

    final durationResult = VoiceDurationParser.parse(lower);
    int detectedDuration = durationResult.durationMinutes;
    String textWithoutDuration = durationResult.cleanedText;

    final Map<String, int> timeWordNumbers = {
      'on iki': 12,
      'on ikiye': 12,
      'on bir': 11,
      'on bire': 11,
      'dokuz': 9,
      'dokuza': 9,
      'sekiz': 8,
      'sekize': 8,
      'yedi': 7,
      'yediye': 7,
      'altı': 6,
      'altıya': 6,
      'beş': 5,
      'beşe': 5,
      'dört': 4,
      'dörde': 4,
      'üç': 3,
      'üçe': 3,
      'iki': 2,
      'ikiye': 2,
      'bir': 1,
      'bire': 1,
      'on': 10,
      'ona': 10,
    };

    int parsedHour = 14;
    int parsedMinute = 0;
    bool hasExplicitTime = false;

    for (var entry in timeWordNumbers.entries) {
      if (textWithoutDuration.contains(entry.key)) {
        if (textWithoutDuration.contains("${entry.key} buçuk")) {
          parsedHour = entry.value;
          parsedMinute = 30;
          hasExplicitTime = true;
          break;
        } else if (textWithoutDuration.contains("${entry.key} çeyrek geçe") ||
            textWithoutDuration.contains("${entry.key}'i çeyrek")) {
          parsedHour = entry.value;
          parsedMinute = 15;
          hasExplicitTime = true;
          break;
        } else if (textWithoutDuration.contains("${entry.key} çeyrek kala") ||
            textWithoutDuration.contains("${entry.key}'e çeyrek")) {
          parsedHour = entry.value - 1;
          parsedMinute = 45;
          hasExplicitTime = true;
          break;
        } else if (textWithoutDuration.contains("saat ${entry.key}") ||
            textWithoutDuration.contains("${entry.key}'de") ||
            textWithoutDuration.contains("${entry.key}'da")) {
          parsedHour = entry.value;
          parsedMinute = 0;
          hasExplicitTime = true;
          break;
        }
      }
    }

    if (!hasExplicitTime) {
      RegExp timePattern = RegExp(
          r"(saat\s*)?([0-2]?[0-9])(:([0-5][0-9]))?\s*(’de|'de|'ta|'te|da|de)?");
      Match? match = timePattern.firstMatch(textWithoutDuration);

      if (match != null && match.group(2) != null) {
        int candidateH = int.tryParse(match.group(2)!) ?? 14;
        if (candidateH >= 0 && candidateH <= 23) {
          parsedHour = candidateH;
          parsedMinute =
              match.group(4) != null ? (int.tryParse(match.group(4)!) ?? 0) : 0;
          hasExplicitTime = true;
        }
      }
    }

    bool isAfternoonOrEvening = lower.contains('akşam') ||
        lower.contains('gece') ||
        lower.contains('öğleden sonra');

    if (hasExplicitTime) {
      if (isAfternoonOrEvening && parsedHour >= 1 && parsedHour <= 11) {
        parsedHour += 12;
      }
    } else {
      if (lower.contains('sabah')) {
        parsedHour = 9;
      } else if (lower.contains('öğlen') || lower.contains('öğle')) {
        parsedHour = 12;
        parsedMinute = 30;
      } else if (lower.contains('öğleden sonra')) {
        parsedHour = 15;
      } else if (lower.contains('akşam')) {
        parsedHour = 19;
      } else if (lower.contains('gece')) {
        parsedHour = 21;
        parsedMinute = 30;
      }
    }

    parsedHour = parsedHour.clamp(0, 23).toInt();
    parsedMinute = parsedMinute.clamp(0, 59).toInt();

    String detectedTaskTime =
        "${parsedHour.toString().padLeft(2, '0')}:${parsedMinute.toString().padLeft(2, '0')}";

    String detectedPriority = 'Orta';
    if (lower.contains('acil') ||
        lower.contains('kritik') ||
        lower.contains('sınav') ||
        lower.contains('vize')) {
      detectedPriority = 'Kritik';
    } else if (lower.contains('önemli') || lower.contains('yüksek')) {
      detectedPriority = 'Yüksek';
    } else if (lower.contains('kolay') ||
        lower.contains('düşük') ||
        lower.contains('mola')) {
      detectedPriority = 'Düşük';
    }

    DateTime? detectedDeadline;
    if (lower.contains('bugün teslim') || lower.contains('akşama kadar')) {
      detectedDeadline = DateTime(now.year, now.month, now.day, 23, 59);
    } else if (lower.contains('yarın teslim') ||
        lower.contains('yarına kadar')) {
      final tom = now.add(const Duration(days: 1));
      detectedDeadline = DateTime(tom.year, tom.month, tom.day, 23, 59);
    } else if (lower.contains('teslim') ||
        lower.contains('deadline') ||
        lower.contains('kadar')) {
      detectedDeadline =
          DateTime(targetDate.year, targetDate.month, targetDate.day, 23, 59);
    }

    String cleanTitle = textWithoutDuration;
    List<String> keywordsToRemove = [
      'pazartesi',
      'salı',
      'çarşamba',
      'perşembe',
      'cuma',
      'cumartesi',
      'pazar',
      'yarın',
      'bugün',
      'sabah',
      'öğlen',
      'öğle',
      'öğleden sonra',
      'akşam',
      'gece',
      'günü',
      'saat',
      'buçuk',
      'çeyrek',
      'geçe',
      'kala',
      'acil',
      'kritik',
      'önemli',
      'teslim',
      'son gün',
      'deadline',
      'kadar',
      'ekle',
      'yapacağım',
      'var',
      'hatırlat'
    ];

    for (var word in keywordsToRemove) {
      cleanTitle = cleanTitle.replaceAll(
          RegExp('\\b$word\\b', caseSensitive: false), '');
    }
    cleanTitle = cleanTitle
        .replaceAll(RegExp(r'\d{1,2}(:\d{2})?'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    return VoiceTaskParseResult(
      title: cleanTitle.isEmpty ? speechText : cleanTitle,
      dayIndex: detectedDayIndex,
      scheduledDate: _formatDateToKey(targetDate),
      taskTime: detectedTaskTime,
      durationMinutes: detectedDuration,
      priority: detectedPriority,
      deadline: detectedDeadline,
      reminderTime: '1 Saat Önce',
      validationError: durationResult.validationError,
    );
  }

  void _showVoiceInputDialog() async {
    final speechController = TextEditingController();
    VoiceTaskParseResult parsedResult = VoiceTaskParseResult(
      title: '',
      dayIndex: (selectedDayIndex < 0 || selectedDayIndex >= 7)
          ? 0
          : selectedDayIndex,
      scheduledDate: _formatDateToKey(DateTime.now()),
      taskTime: '10:00',
      durationMinutes: 60,
      priority: 'Orta',
    );

    bool available = false;
    try {
      available = await _speechToText.initialize(
        onError: (val) => debugPrint('Mikrofon Hatası: $val'),
        onStatus: (val) => debugPrint('Mikrofon Durumu: $val'),
      );
    } catch (e) {
      debugPrint('Speech Init Hatası: $e');
    }

    if (!mounted) {
      return;
    }

    bool isVoiceSaving = false;

    showDialog(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            void startListening() async {
              if (available) {
                if (dialogContext.mounted) {
                  setStateDialog(() => _isListening = true);
                }
                await _speechToText.listen(
                  onResult: (result) {
                    if (dialogContext.mounted) {
                      setStateDialog(() {
                        speechController.text = result.recognizedWords;
                        parsedResult =
                            _parseVoiceCommandToTask(result.recognizedWords);
                      });
                    }
                  },
                );
              } else {
                if (dialogContext.mounted) {
                  ScaffoldMessenger.of(dialogContext).showSnackBar(
                    const SnackBar(
                        content: Text(
                            'Mikrofon erişimi sağlanamadı veya cihazınızda desteklenmiyor.')),
                  );
                }
              }
            }

            void stopListening() {
              try {
                _speechToText.stop();
              } catch (_) {}
              if (dialogContext.mounted) {
                setStateDialog(() => _isListening = false);
              }
            }

            final hasValidationError = parsedResult.validationError != null;

            return AlertDialog(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24)),
              title: const Text('Akıllı Sesli Asistan 🎙️',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontWeight: FontWeight.bold)),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    GestureDetector(
                      onTap: _isListening ? stopListening : startListening,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 300),
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: _isListening
                              ? Colors.redAccent
                              : const Color(0xFF7895CB),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          _isListening ? Icons.mic : Icons.mic_none,
                          color: Colors.white,
                          size: 36,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: speechController,
                      maxLines: 2,
                      decoration: const InputDecoration(
                        labelText: 'Algılanan Metin',
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (text) {
                        if (dialogContext.mounted) {
                          setStateDialog(() {
                            parsedResult = _parseVoiceCommandToTask(text);
                          });
                        }
                      },
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: widget.isDark
                            ? Colors.grey.shade800
                            : Colors.grey.shade200,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                              '📌 Başlık: ${parsedResult.title.isEmpty ? '---' : parsedResult.title}',
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold, fontSize: 13)),
                          const SizedBox(height: 4),
                          Text(
                              '📅 Tarih: ${parsedResult.scheduledDate} (${fullWeekDays[parsedResult.dayIndex]})',
                              style: const TextStyle(
                                  color: Colors.blue,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600)),
                          const SizedBox(height: 4),
                          Text(
                              '⏰ Saat & Süre: ${parsedResult.taskTime} (${parsedResult.durationMinutes} dk)',
                              style: const TextStyle(
                                  color: Colors.deepPurple,
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold)),
                          if (parsedResult.deadline != null) ...[
                            const SizedBox(height: 4),
                            Text(
                                '🎯 Son Teslim: ${parsedResult.deadline!.day}/${parsedResult.deadline!.month} ${parsedResult.deadline!.hour.toString().padLeft(2, '0')}:${parsedResult.deadline!.minute.toString().padLeft(2, '0')}',
                                style: const TextStyle(
                                    color: Colors.redAccent,
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold)),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    stopListening();
                    if (dialogContext.mounted) {
                      Navigator.pop(dialogContext);
                    }
                  },
                  child: const Text('İptal'),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                      backgroundColor: (hasValidationError || isVoiceSaving)
                          ? Colors.grey
                          : const Color(0xFF7895CB)),
                  onPressed: (hasValidationError || isVoiceSaving)
                      ? null
                      : () async {
                          if (speechController.text.trim().isEmpty) {
                            return;
                          }

                          setStateDialog(() => isVoiceSaving = true);
                          stopListening();
                          final userId = supabase.auth.currentUser?.id;
                          if (userId == null) {
                            if (dialogContext.mounted) {
                              setStateDialog(() => isVoiceSaving = false);
                              Navigator.pop(dialogContext);
                            }
                            return;
                          }

                          final scaffoldMessenger =
                              ScaffoldMessenger.of(context);
                          final randomSuffix = Random()
                              .nextInt(999999)
                              .toString()
                              .padLeft(6, '0');
                          final String requestId =
                              "voice_${userId}_${DateTime.now().millisecondsSinceEpoch}_$randomSuffix";

                          try {
                            final targetDate =
                                DateTime.parse(parsedResult.scheduledDate);
                            final derivedWeekStart = targetDate.subtract(
                                Duration(days: targetDate.weekday - 1));
                            final derivedDayIndex = targetDate.weekday - 1;

                            final dynamic response = await supabase.rpc(
                              'create_voice_task_with_quota',
                              params: {
                                'p_request_id': requestId,
                                'p_title': parsedResult.title,
                                'p_category': 'Sesli Plan',
                                'p_day_index': derivedDayIndex,
                                'p_scheduled_date': parsedResult.scheduledDate,
                                'p_week_start_date':
                                    _formatDateToKey(derivedWeekStart),
                                'p_task_time': parsedResult.taskTime,
                                'p_duration_minutes':
                                    parsedResult.durationMinutes,
                                'p_priority': parsedResult.priority,
                                'p_deadline':
                                    parsedResult.deadline?.toIso8601String(),
                                'p_reminder_time': parsedResult.reminderTime,
                              },
                            );

                            if (response is! Map ||
                                response['success'] != true) {
                              if (dialogContext.mounted) {
                                Navigator.pop(dialogContext);
                              }
                              if (!mounted) return;
                              final message = (response is Map)
                                  ? response['message']
                                  : null;
                              _showLimitExceededDialog(
                                title: 'Haftalık Sesli Komut Hakkın Doldu! 🎙️',
                                message: message ??
                                    'Ücretsiz sürümde haftada en fazla 3 kez sesli komut kullanabilirsin.',
                              );
                              return;
                            }

                            final createdTask =
                                TaskItem.fromJson(response['task']);

                            if (dialogContext.mounted) {
                              Navigator.pop(dialogContext);
                            }

                            final syncResult =
                                await TaskSyncCoordinator.coordinateTaskSync(
                              task: createdTask,
                              targetDate: targetDate,
                            );

                            if (!mounted) return;

                            _fetchTasks();
                            _fetchAllTasksForMonth(focusedCalendarDay);

                            if (!syncResult.isFullySynced && mounted) {
                              final msg = syncResult.effectiveUserMessage ??
                                  'Senkronizasyon tamamlanamadı.';
                              scaffoldMessenger.showSnackBar(
                                SnackBar(
                                    content: Text('⚠️ Plan eklendi: $msg')),
                              );
                            }
                          } catch (e) {
                            debugPrint("Sesli Görev Ekleme Hatası: $e");
                            if (dialogContext.mounted) {
                              setStateDialog(() => isVoiceSaving = false);
                              Navigator.pop(dialogContext);
                            }
                            if (mounted) {
                              scaffoldMessenger.showSnackBar(
                                SnackBar(
                                    content: Text('Görev kaydedilemedi: $e')),
                              );
                            }
                          }
                        },
                  child: isVoiceSaving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              color: Colors.white, strokeWidth: 2))
                      : const Text('Ekle 🚀',
                          style: TextStyle(color: Colors.white)),
                ),
              ],
            );
          },
        );
      },
    ).whenComplete(() {
      try {
        _speechToText.stop();
      } catch (_) {}
      speechController.dispose();
    });
  }

  void _showEditTaskDialog(TaskItem task) {
    final titleController = TextEditingController(text: task.title);
    final List<String> availableCategories = task.taskMode == 'student'
        ? ['Ders / Ödev', 'Sınav', 'Proje', 'Sesli Plan', 'Genel']
        : ['Toplantı / İş', 'Müşteri', 'Proje', 'Sesli Plan', 'Genel'];

    String selectedCategory = availableCategories.contains(task.category)
        ? task.category
        : (task.taskMode == 'student' ? 'Ders / Ödev' : 'Toplantı / İş');

    String selectedReminder = task.reminderTime;
    int selectedDuration = task.durationMinutes;
    String selectedPriority = task.priority;
    DateTime? selectedDeadline = task.deadline;

    int initHour = 10, initMinute = 0;
    try {
      final parts = task.taskTime.split(':');
      if (parts.length == 2) {
        initHour = int.parse(parts[0]);
        initMinute = int.parse(parts[1]);
      }
    } catch (_) {}

    TimeOfDay selectedTime = TimeOfDay(hour: initHour, minute: initMinute);
    int targetDay = task.dayIndex;
    bool isEditSaving = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (modalContext) {
        return StatefulBuilder(
          builder: (BuildContext innerContext, StateSetter setStateModal) {
            return Padding(
              padding: EdgeInsets.only(
                  bottom: MediaQuery.of(modalContext).viewInsets.bottom + 20,
                  top: 24,
                  left: 20,
                  right: 20),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Görevi Düzenle ✏️',
                        style: TextStyle(
                            fontSize: 20, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 16),
                    TextField(
                      controller: titleController,
                      decoration: const InputDecoration(
                        labelText: 'Görev Başlığı',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Başlangıç Saati:',
                            style: TextStyle(fontWeight: FontWeight.bold)),
                        OutlinedButton.icon(
                          icon: const Icon(Icons.access_time, size: 18),
                          label: Text(
                              "${selectedTime.hour.toString().padLeft(2, '0')}:${selectedTime.minute.toString().padLeft(2, '0')}"),
                          onPressed: () async {
                            final picked = await showTimePicker(
                                context: modalContext,
                                initialTime: selectedTime);
                            if (picked != null && modalContext.mounted) {
                              setStateModal(() => selectedTime = picked);
                            }
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Tahmini Süre:',
                            style: TextStyle(fontWeight: FontWeight.bold)),
                        DropdownButton<int>(
                          value: selectedDuration,
                          items: [
                            15,
                            30,
                            45,
                            60,
                            90,
                            120,
                            180,
                            240,
                            300,
                            360,
                            420,
                            480
                          ]
                              .map((d) => DropdownMenuItem(
                                  value: d, child: Text('$d Dakika')))
                              .toList(),
                          onChanged: (val) {
                            if (val != null && modalContext.mounted) {
                              setStateModal(() => selectedDuration = val);
                            }
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Öncelik Seviyesi:',
                            style: TextStyle(fontWeight: FontWeight.bold)),
                        DropdownButton<String>(
                          value: selectedPriority,
                          items: ['Düşük', 'Orta', 'Yüksek', 'Kritik']
                              .map((p) =>
                                  DropdownMenuItem(value: p, child: Text(p)))
                              .toList(),
                          onChanged: (val) {
                            if (val != null && modalContext.mounted) {
                              setStateModal(() => selectedPriority = val);
                            }
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Son Teslim (Deadline):',
                            style: TextStyle(fontWeight: FontWeight.bold)),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            OutlinedButton.icon(
                              icon: const Icon(Icons.event_available, size: 18),
                              label: Text(
                                selectedDeadline == null
                                    ? 'Seçilmedi'
                                    : '${selectedDeadline!.day}/${selectedDeadline!.month} ${selectedDeadline!.hour.toString().padLeft(2, '0')}:${selectedDeadline!.minute.toString().padLeft(2, '0')}',
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold),
                              ),
                              onPressed: () async {
                                final now = DateTime.now();
                                final firstDate =
                                    now.subtract(const Duration(days: 365));
                                final lastDate =
                                    now.add(const Duration(days: 730));

                                DateTime initialDate = selectedDeadline ?? now;
                                if (initialDate.isBefore(firstDate)) {
                                  initialDate = firstDate;
                                } else if (initialDate.isAfter(lastDate)) {
                                  initialDate = lastDate;
                                }

                                final DateTime? pickedDate =
                                    await showDatePicker(
                                  context: modalContext,
                                  initialDate: initialDate,
                                  firstDate: firstDate,
                                  lastDate: lastDate,
                                );

                                if (pickedDate == null ||
                                    !modalContext.mounted) {
                                  return;
                                }

                                final TimeOfDay? pickedTime =
                                    await showTimePicker(
                                  context: modalContext,
                                  initialTime: selectedDeadline != null
                                      ? TimeOfDay(
                                          hour: selectedDeadline!.hour,
                                          minute: selectedDeadline!.minute)
                                      : const TimeOfDay(hour: 23, minute: 59),
                                );

                                if (pickedTime != null &&
                                    modalContext.mounted) {
                                  setStateModal(
                                      () => selectedDeadline = DateTime(
                                            pickedDate.year,
                                            pickedDate.month,
                                            pickedDate.day,
                                            pickedTime.hour,
                                            pickedTime.minute,
                                          ));
                                }
                              },
                            ),
                            if (selectedDeadline != null) ...[
                              const SizedBox(width: 4),
                              IconButton(
                                icon: const Icon(Icons.clear,
                                    size: 18, color: Colors.redAccent),
                                tooltip: 'Deadline Kaldır',
                                onPressed: () {
                                  if (modalContext.mounted) {
                                    setStateModal(
                                        () => selectedDeadline = null);
                                  }
                                },
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                            backgroundColor: task.taskMode == 'student'
                                ? const Color(0xFF4A55A2)
                                : const Color(0xFF1E293B)),
                        onPressed: isEditSaving
                            ? null
                            : () async {
                                final newTitle = titleController.text.trim();
                                if (newTitle.isEmpty) {
                                  return;
                                }

                                final newDate = currentWeekMonday
                                    .add(Duration(days: targetDay));
                                final taskStart = DateTime(
                                  newDate.year,
                                  newDate.month,
                                  newDate.day,
                                  selectedTime.hour,
                                  selectedTime.minute,
                                );
                                final taskEnd = taskStart
                                    .add(Duration(minutes: selectedDuration));
                                final scaffoldMessenger =
                                    ScaffoldMessenger.of(context);

                                if (selectedDeadline != null &&
                                    taskEnd.isAfter(selectedDeadline!)) {
                                  scaffoldMessenger.showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                          '⚠️ Görev bitiş saati teslim tarihinden (deadline) sonra olamaz!'),
                                      backgroundColor: Colors.redAccent,
                                    ),
                                  );
                                  return;
                                }

                                setStateModal(() => isEditSaving = true);
                                final formattedTime =
                                    "${selectedTime.hour.toString().padLeft(2, '0')}:${selectedTime.minute.toString().padLeft(2, '0')}";
                                final derivedWeekStart = newDate.subtract(
                                    Duration(days: newDate.weekday - 1));
                                final derivedDayIndex = newDate.weekday - 1;

                                try {
                                  final res = await supabase.rpc(
                                    'save_task_mutation',
                                    params: {
                                      'p_task_id': task.id,
                                      'p_title': newTitle,
                                      'p_category': selectedCategory,
                                      'p_day_index': derivedDayIndex,
                                      'p_scheduled_date':
                                          _formatDateToKey(newDate),
                                      'p_week_start_date':
                                          _formatDateToKey(derivedWeekStart),
                                      'p_task_time': formattedTime,
                                      'p_duration_minutes': selectedDuration,
                                      'p_priority': selectedPriority,
                                      'p_deadline':
                                          selectedDeadline?.toIso8601String(),
                                      'p_reminder_time': selectedReminder,
                                      'p_is_completed': task.isCompleted,
                                    },
                                  );

                                  task.title = newTitle;
                                  task.category = selectedCategory;
                                  task.dayIndex = derivedDayIndex;
                                  task.scheduledDate =
                                      _formatDateToKey(newDate);
                                  task.weekStartDate =
                                      _formatDateToKey(derivedWeekStart);
                                  task.taskTime = formattedTime;
                                  task.durationMinutes = selectedDuration;
                                  task.priority = selectedPriority;
                                  task.deadline = selectedDeadline;
                                  task.reminderTime = selectedReminder;
                                  if (res is Map && res['success'] == true) {
                                    task.version =
                                        res['version'] ?? (task.version + 1);
                                  }

                                  if (modalContext.mounted) {
                                    Navigator.pop(modalContext);
                                  }

                                  final syncResult = await TaskSyncCoordinator
                                      .coordinateTaskSync(
                                    task: task,
                                    targetDate: newDate,
                                  );

                                  if (!mounted) {
                                    return;
                                  }

                                  _fetchTasks();
                                  _fetchAllTasksForMonth(focusedCalendarDay);

                                  if (!syncResult.isFullySynced && mounted) {
                                    final msg =
                                        syncResult.effectiveUserMessage ??
                                            'Senkronizasyon tamamlanamadı.';
                                    scaffoldMessenger.showSnackBar(
                                      SnackBar(
                                          content:
                                              Text('⚠️ Güncellendi: $msg')),
                                    );
                                  }
                                } catch (e) {
                                  debugPrint("Görev Güncelleme Hatası: $e");
                                  if (modalContext.mounted) {
                                    setStateModal(() => isEditSaving = false);
                                  }
                                }
                              },
                        child: isEditSaving
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    color: Colors.white, strokeWidth: 2))
                            : const Text('Güncelle ve Kaydet 👍',
                                style: TextStyle(color: Colors.white)),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    ).whenComplete(() {
      titleController.dispose();
    });
  }

  void _showAddTaskDialog() {
    final titleController = TextEditingController();
    String selectedCategory =
        activeMode == 'student' ? 'Ders / Ödev' : 'Toplantı / İş';
    String selectedReminder = '1 Saat Önce';
    int selectedDuration = 60;
    String selectedPriority = 'Orta';
    DateTime? selectedDeadline;
    TimeOfDay selectedTime = const TimeOfDay(hour: 10, minute: 0);
    int targetDay =
        (selectedDayIndex < 0 || selectedDayIndex >= 7) ? 0 : selectedDayIndex;
    bool isAddSaving = false;
    String? modalError;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (modalContext) {
        return StatefulBuilder(
          builder: (BuildContext innerContext, StateSetter setStateModal) {
            return Padding(
              padding: EdgeInsets.only(
                  bottom: MediaQuery.of(modalContext).viewInsets.bottom + 20,
                  top: 24,
                  left: 20,
                  right: 20),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                        'Yeni ${activeMode == 'student' ? 'Akademik Plan' : 'İş Görevi'} Ekle',
                        style: const TextStyle(
                            fontSize: 20, fontWeight: FontWeight.bold)),
                    if (modalError != null) ...[
                      const SizedBox(height: 8),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.red.shade100,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          modalError!,
                          style: const TextStyle(
                              color: Colors.red,
                              fontSize: 12,
                              fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    TextField(
                      controller: titleController,
                      autofocus: true,
                      decoration: InputDecoration(
                        labelText: 'Görev Başlığı',
                        hintText: activeMode == 'student'
                            ? 'Örn: Finans Vize Çalışması'
                            : 'Örn: Çeyrek Rapor Sunumu',
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Başlangıç Saati:',
                            style: TextStyle(fontWeight: FontWeight.bold)),
                        OutlinedButton.icon(
                          icon: const Icon(Icons.access_time, size: 18),
                          label: Text(
                              "${selectedTime.hour.toString().padLeft(2, '0')}:${selectedTime.minute.toString().padLeft(2, '0')}"),
                          onPressed: () async {
                            final picked = await showTimePicker(
                                context: modalContext,
                                initialTime: selectedTime);
                            if (picked != null && modalContext.mounted) {
                              setStateModal(() => selectedTime = picked);
                            }
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Tahmini Süre:',
                            style: TextStyle(fontWeight: FontWeight.bold)),
                        DropdownButton<int>(
                          value: selectedDuration,
                          items: [
                            15,
                            30,
                            45,
                            60,
                            90,
                            120,
                            180,
                            240,
                            300,
                            360,
                            420,
                            480
                          ]
                              .map((d) => DropdownMenuItem(
                                  value: d, child: Text('$d Dakika')))
                              .toList(),
                          onChanged: (val) {
                            if (val != null && modalContext.mounted) {
                              setStateModal(() => selectedDuration = val);
                            }
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Öncelik:',
                            style: TextStyle(fontWeight: FontWeight.bold)),
                        DropdownButton<String>(
                          value: selectedPriority,
                          items: ['Düşük', 'Orta', 'Yüksek', 'Kritik']
                              .map((p) =>
                                  DropdownMenuItem(value: p, child: Text(p)))
                              .toList(),
                          onChanged: (val) {
                            if (val != null && modalContext.mounted) {
                              setStateModal(() => selectedPriority = val);
                            }
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Son Teslim (Deadline):',
                            style: TextStyle(fontWeight: FontWeight.bold)),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            OutlinedButton.icon(
                              icon: const Icon(Icons.event_available, size: 18),
                              label: Text(
                                selectedDeadline == null
                                    ? 'Seçilmedi'
                                    : '${selectedDeadline!.day}/${selectedDeadline!.month} ${selectedDeadline!.hour.toString().padLeft(2, '0')}:${selectedDeadline!.minute.toString().padLeft(2, '0')}',
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold),
                              ),
                              onPressed: () async {
                                final now = DateTime.now();
                                final firstDate =
                                    now.subtract(const Duration(days: 365));
                                final lastDate =
                                    now.add(const Duration(days: 730));

                                DateTime initialDate = selectedDeadline ?? now;
                                if (initialDate.isBefore(firstDate)) {
                                  initialDate = firstDate;
                                } else if (initialDate.isAfter(lastDate)) {
                                  initialDate = lastDate;
                                }

                                final DateTime? pickedDate =
                                    await showDatePicker(
                                  context: modalContext,
                                  initialDate: initialDate,
                                  firstDate: firstDate,
                                  lastDate: lastDate,
                                );

                                if (pickedDate == null ||
                                    !modalContext.mounted) {
                                  return;
                                }

                                final TimeOfDay? pickedTime =
                                    await showTimePicker(
                                  context: modalContext,
                                  initialTime:
                                      const TimeOfDay(hour: 23, minute: 59),
                                );
                                if (pickedTime != null &&
                                    modalContext.mounted) {
                                  setStateModal(
                                      () => selectedDeadline = DateTime(
                                            pickedDate.year,
                                            pickedDate.month,
                                            pickedDate.day,
                                            pickedTime.hour,
                                            pickedTime.minute,
                                          ));
                                }
                              },
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                            backgroundColor: activeMode == 'student'
                                ? const Color(0xFF4A55A2)
                                : const Color(0xFF1E293B)),
                        onPressed: isAddSaving
                            ? null
                            : () async {
                                final title = titleController.text.trim();
                                if (title.isEmpty) {
                                  setStateModal(() =>
                                      modalError = 'Lütfen bir başlık yazın!');
                                  return;
                                }

                                final user = supabase.auth.currentUser;
                                if (user == null) {
                                  setStateModal(() => modalError =
                                      'Oturum bulunamadı! Çıkış yapıp tekrar girin.');
                                  return;
                                }

                                DateTime targetDate =
                                    (currentViewMode == ViewMode.monthly)
                                        ? selectedCalendarDay
                                        : currentWeekMonday
                                            .add(Duration(days: targetDay));

                                final taskStart = DateTime(
                                  targetDate.year,
                                  targetDate.month,
                                  targetDate.day,
                                  selectedTime.hour,
                                  selectedTime.minute,
                                );
                                final taskEnd = taskStart
                                    .add(Duration(minutes: selectedDuration));

                                if (selectedDeadline != null &&
                                    taskEnd.isAfter(selectedDeadline!)) {
                                  setStateModal(() => modalError =
                                      'Bitiş saati teslim tarihinden sonra olamaz!');
                                  return;
                                }

                                setStateModal(() {
                                  isAddSaving = true;
                                  modalError = null;
                                });

                                final formattedTime =
                                    "${selectedTime.hour.toString().padLeft(2, '0')}:${selectedTime.minute.toString().padLeft(2, '0')}";
                                final derivedWeekStart = targetDate.subtract(
                                    Duration(days: targetDate.weekday - 1));
                                final derivedDayIndex = targetDate.weekday - 1;

                                try {
                                  dynamic rpcRes;
                                  try {
                                    rpcRes = await supabase.rpc(
                                      'create_task_with_outbox',
                                      params: {
                                        'p_title': title,
                                        'p_category': selectedCategory,
                                        'p_day_index': derivedDayIndex,
                                        'p_scheduled_date':
                                            _formatDateToKey(targetDate),
                                        'p_week_start_date':
                                            _formatDateToKey(derivedWeekStart),
                                        'p_task_mode': activeMode,
                                        'p_task_time': formattedTime,
                                        'p_duration_minutes': selectedDuration,
                                        'p_priority': selectedPriority,
                                        'p_deadline':
                                            selectedDeadline?.toIso8601String(),
                                        'p_reminder_time': selectedReminder,
                                      },
                                    );
                                  } catch (rpcErr) {
                                    debugPrint(
                                        "RPC Hatası, doğrudan tablo insert'ine dönülüyor: $rpcErr");
                                  }

                                  TaskItem createdTask;

                                  if (rpcRes is Map &&
                                      rpcRes['success'] == true &&
                                      rpcRes['task'] != null) {
                                    createdTask =
                                        TaskItem.fromJson(rpcRes['task']);
                                  } else {
                                    final rawInsert = await supabase
                                        .from('weekly_tasks')
                                        .insert({
                                          'user_id': user.id,
                                          'title': title,
                                          'category': selectedCategory,
                                          'day_index': derivedDayIndex,
                                          'scheduled_date':
                                              _formatDateToKey(targetDate),
                                          'week_start_date': _formatDateToKey(
                                              derivedWeekStart),
                                          'task_mode': activeMode,
                                          'task_time': formattedTime,
                                          'duration_minutes': selectedDuration,
                                          'priority': selectedPriority,
                                          'deadline': selectedDeadline
                                              ?.toIso8601String(),
                                          'reminder_time': selectedReminder,
                                          'is_completed': false,
                                          'version': 1,
                                          'sync_status': 'pending',
                                        })
                                        .select()
                                        .single();

                                    createdTask = TaskItem.fromJson(rawInsert);
                                  }

                                  if (modalContext.mounted) {
                                    Navigator.pop(modalContext);
                                  }

                                  _fetchTasks();
                                  _fetchAllTasksForMonth(focusedCalendarDay);

                                  TaskSyncCoordinator.coordinateTaskSync(
                                    task: createdTask,
                                    targetDate: targetDate,
                                  );

                                  if (mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content:
                                            Text('✨ Görev başarıyla eklendi!'),
                                        backgroundColor: Colors.green,
                                      ),
                                    );
                                  }
                                } catch (e) {
                                  debugPrint("Görev Ekleme Kritik Hata: $e");
                                  if (modalContext.mounted) {
                                    setStateModal(() {
                                      isAddSaving = false;
                                      modalError = 'Kayıt Hatası: $e';
                                    });
                                  }
                                }
                              },
                        child: isAddSaving
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                    color: Colors.white, strokeWidth: 2))
                            : const Text('Kaydet ve Ekle 🚀',
                                style: TextStyle(color: Colors.white)),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    ).whenComplete(() {
      titleController.dispose();
    });
  }

  Future<void> _fetchTasks() async {
    setState(() => _isLoadingTasks = true);
    try {
      final user = supabase.auth.currentUser;
      if (user == null) {
        return;
      }

      final weekKey = _formatDateToKey(currentWeekMonday);
      final response = await supabase
          .from('weekly_tasks')
          .select()
          .eq('user_id', user.id)
          .eq('week_start_date', weekKey)
          .order('scheduled_date', ascending: true)
          .order('task_time', ascending: true);

      List<TaskItem> loaded = [];
      for (var row in response) {
        loaded.add(TaskItem.fromJson(row));
      }

      if (mounted) {
        setState(() => allFetchedTasks = loaded);
      }
    } catch (e) {
      debugPrint('Çekme Hatası: $e');
    } finally {
      if (mounted) {
        setState(() => _isLoadingTasks = false);
      }
    }
  }

  Future<void> _fetchAllTasksForMonth(DateTime monthDate) async {
    try {
      final user = supabase.auth.currentUser;
      if (user == null) {
        return;
      }

      final firstDay = DateTime(monthDate.year, monthDate.month - 1, 20);
      final lastDay = DateTime(monthDate.year, monthDate.month + 1, 10);

      final response = await supabase
          .from('weekly_tasks')
          .select()
          .eq('user_id', user.id)
          .gte('scheduled_date', _formatDateToKey(firstDay))
          .lte('scheduled_date', _formatDateToKey(lastDay))
          .order('scheduled_date', ascending: true)
          .order('task_time', ascending: true);

      List<TaskItem> loaded = [];
      for (var row in response) {
        loaded.add(TaskItem.fromJson(row));
      }

      if (mounted) {
        setState(() => allMonthFetchedTasks = loaded);
      }
    } catch (e) {
      debugPrint("Ay Görevleri Çekme Hatası: $e");
    }
  }

  Future<TaskMoveResult> _moveTaskToNewDay(
      TaskItem task, int newDayIndex) async {
    if (!_movingTaskIds.add(task.id)) {
      return const TaskMoveResult(
          status: TaskMoveStatus.busy, message: 'İşlem sürüyor.');
    }

    final oldDayIndex = task.dayIndex;
    final oldScheduledDate = task.scheduledDate;
    final oldWeekStartDate = task.weekStartDate;

    final newDate = currentWeekMonday.add(Duration(days: newDayIndex));
    final derivedWeekStart =
        newDate.subtract(Duration(days: newDate.weekday - 1));
    final derivedDayIndex = newDate.weekday - 1;
    final user = supabase.auth.currentUser;

    if (user == null) {
      _movingTaskIds.remove(task.id);
      return const TaskMoveResult(
          status: TaskMoveStatus.failed, message: 'Oturum bulunamadı.');
    }

    try {
      final updateRes = await supabase.rpc(
        'save_task_mutation',
        params: {
          'p_task_id': task.id,
          'p_title': task.title,
          'p_category': task.category,
          'p_day_index': derivedDayIndex,
          'p_scheduled_date': _formatDateToKey(newDate),
          'p_week_start_date': _formatDateToKey(derivedWeekStart),
          'p_task_time': task.taskTime,
          'p_duration_minutes': task.durationMinutes,
          'p_priority': task.priority,
          'p_deadline': task.deadline?.toIso8601String(),
          'p_reminder_time': task.reminderTime,
          'p_is_completed': task.isCompleted,
        },
      );

      if (updateRes is! Map || updateRes['success'] != true) {
        _movingTaskIds.remove(task.id);
        return const TaskMoveResult(
          status: TaskMoveStatus.failed,
          message: 'Görev veritabanında bulunamadı veya güncellenemedi.',
        );
      }

      setState(() {
        task.dayIndex = derivedDayIndex;
        task.scheduledDate = _formatDateToKey(newDate);
        task.weekStartDate = _formatDateToKey(derivedWeekStart);
        task.version = updateRes['version'] ?? (task.version + 1);
      });

      final syncResult = await TaskSyncCoordinator.coordinateTaskSync(
        task: task,
        targetDate: newDate,
      );

      _fetchTasks();
      _fetchAllTasksForMonth(focusedCalendarDay);

      if (syncResult.isFullySynced) {
        return const TaskMoveResult(status: TaskMoveStatus.success);
      } else {
        return TaskMoveResult(
          status: TaskMoveStatus.partial,
          message: syncResult.effectiveUserMessage ?? 'Senkronizasyon kısmi.',
        );
      }
    } catch (e) {
      debugPrint("Taşıma Hatası: $e");
      if (mounted) {
        setState(() {
          task.dayIndex = oldDayIndex;
          task.scheduledDate = oldScheduledDate;
          task.weekStartDate = oldWeekStartDate;
        });
      }
      return const TaskMoveResult(
        status: TaskMoveStatus.failed,
        message: 'Görev taşınamadı. Lütfen internet bağlantınızı kontrol edin.',
      );
    } finally {
      _movingTaskIds.remove(task.id);
    }
  }

  Map<int, List<TaskItem>> _getFilteredTasksForCurrentMode() {
    Map<int, List<TaskItem>> filteredMap = {};
    for (var task in allFetchedTasks) {
      if (task.taskMode == activeMode) {
        filteredMap.putIfAbsent(task.dayIndex, () => []).add(task);
      }
    }
    return filteredMap;
  }

  void _confirmDeleteTask(TaskItem task) {
    showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Text('Görevi Sil 🗑️',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          content: Text(
            '"${task.title}" adlı görevi silmek istediğinize emin misiniz?',
            style: const TextStyle(fontSize: 13, color: Colors.grey),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Vazgeç'),
            ),
            ElevatedButton(
              style:
                  ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
              onPressed: () async {
                Navigator.pop(dialogContext);
                final scaffoldMessenger = ScaffoldMessenger.of(context);

                setState(() {
                  allFetchedTasks.removeWhere((t) => t.id == task.id);
                  allMonthFetchedTasks.removeWhere((t) => t.id == task.id);
                });

                try {
                  final res = await supabase.rpc(
                    'delete_task_durable',
                    params: {'p_task_id': task.id},
                  );

                  if (res is Map && res['success'] == false) {
                    throw Exception(
                        res['message'] ?? 'Silme işlemi başarısız.');
                  }

                  final int notifIdToCancel =
                      NotificationService.resolveNotificationId(task: task);
                  await NotificationService.cancelNotification(notifIdToCancel);

                  if (task.calendarId != null && task.calendarEventId != null) {
                    await CalendarService.deleteEvent(
                        task.calendarId!, task.calendarEventId!);
                  }
                } catch (e) {
                  debugPrint("Silme Hatası: $e");
                  if (mounted) {
                    scaffoldMessenger.showSnackBar(
                      const SnackBar(
                          content:
                              Text('Silme işlemi veritabanına yansıtılamadı.')),
                    );
                  }
                  _fetchTasks();
                }
              },
              child: const Text('Sil',
                  style: TextStyle(
                      color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
    );
  }

  void _updateTaskCompletion(TaskItem task, bool isCompleted) async {
    final previousState = task.isCompleted;
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    setState(() => task.isCompleted = isCompleted);

    try {
      final res = await supabase.rpc(
        'save_task_mutation',
        params: {
          'p_task_id': task.id,
          'p_title': task.title,
          'p_category': task.category,
          'p_day_index': task.dayIndex,
          'p_scheduled_date': task.scheduledDate ?? '',
          'p_week_start_date': task.weekStartDate ?? '',
          'p_task_time': task.taskTime,
          'p_duration_minutes': task.durationMinutes,
          'p_priority': task.priority,
          'p_deadline': task.deadline?.toIso8601String(),
          'p_reminder_time': task.reminderTime,
          'p_is_completed': isCompleted,
        },
      );

      if (res is Map && res['success'] == true) {
        task.version = res['version'] ?? (task.version + 1);
      }
    } catch (_) {
      if (mounted) {
        setState(() => task.isCompleted = previousState);
        scaffoldMessenger.showSnackBar(
          const SnackBar(content: Text('Görev durumu güncellenemedi.')),
        );
      }
    }
  }

  Color _getWorkloadColor(int score) {
    if (score == 0) return Colors.grey.shade400;
    if (score < 40) return Colors.green;
    if (score < 75) return Colors.blue;
    if (score <= 100) return Colors.orange;
    return Colors.redAccent;
  }

  String _getWorkloadLabel(int score) {
    if (score == 0) return "Boş / Serbest";
    if (score < 40) return "Hafif & Rahat ☕";
    if (score < 75) return "İdeal & Dengeli ⚡";
    if (score <= 100) return "Yoğun Kapasite 💼";
    return "Aşırı Yük 🚨";
  }

  @override
  Widget build(BuildContext context) {
    bool isStudent = activeMode == 'student';
    Color primaryColor =
        isStudent ? const Color(0xFF4A55A2) : const Color(0xFF1E293B);

    DateTime sundayOfCurrentWeek =
        currentWeekMonday.add(const Duration(days: 6));
    String headerTitle =
        "${currentWeekMonday.day} ${monthNames[currentWeekMonday.month - 1]} - ${sundayOfCurrentWeek.day} ${monthNames[sundayOfCurrentWeek.month - 1]} ${sundayOfCurrentWeek.year}";

    Map<int, List<TaskItem>> activeModeTasks =
        _getFilteredTasksForCurrentMode();

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('WeeklyPulse',
                    style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: widget.isDark ? Colors.white : primaryColor,
                        fontSize: 18)),
                const SizedBox(width: 8),
                if (isUserPremium)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(colors: [
                        Colors.amber.shade700,
                        Colors.amber.shade400
                      ]),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      userTierName,
                      style: const TextStyle(
                          color: Colors.black,
                          fontWeight: FontWeight.bold,
                          fontSize: 9),
                    ),
                  ),
              ],
            ),
            Text(
              isStudent ? '🎓 Akademik Ajanda' : '💼 Kurumsal İş Akışı',
              style: TextStyle(
                  fontSize: 10,
                  color: widget.isDark
                      ? Colors.grey
                      : primaryColor.withValues(alpha: 0.8),
                  fontWeight: FontWeight.w600),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(isUserPremium ? Icons.stars : Icons.workspace_premium,
                color: Colors.amber),
            onPressed: _showPricingModal,
            tooltip: 'Elit Üyelik',
          ),
          IconButton(
            icon: const Icon(Icons.mic, color: Colors.redAccent),
            onPressed: _showVoiceInputDialog,
            tooltip: 'Sesli Kaydet',
          ),
          IconButton(
            icon: Icon(
                widget.isDark ? Icons.light_mode : Icons.dark_mode_outlined),
            onPressed: widget.onThemeToggle,
            tooltip: 'Gece/Gündüz Modu',
          ),
          IconButton(
            icon: const Icon(Icons.account_circle_outlined, size: 26),
            onPressed: _showProfileDialog,
            tooltip: 'Profil ve Üyelik',
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: primaryColor,
        onPressed: _showAddTaskDialog,
        icon: const Icon(Icons.add, color: Colors.white),
        label: Text(isStudent ? 'Plan Ekle' : 'Görev Ekle',
            style: const TextStyle(color: Colors.white)),
      ),
      body: _isLoadingTasks
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Container(
                  margin:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: Theme.of(context).cardColor,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: GestureDetector(
                          onTap: () => _switchMode('student'),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            decoration: BoxDecoration(
                              color: isStudent
                                  ? const Color(0xFF4A55A2)
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Center(
                              child: Text(
                                '🎓 Öğrenci Modu',
                                style: TextStyle(
                                  color: isStudent ? Colors.white : Colors.grey,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      Expanded(
                        child: GestureDetector(
                          onTap: () => _switchMode('pro'),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            decoration: BoxDecoration(
                              color: !isStudent
                                  ? const Color(0xFF1E293B)
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Center(
                              child: Text(
                                '💼 Pro / İş Modu',
                                style: TextStyle(
                                  color:
                                      !isStudent ? Colors.white : Colors.grey,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  margin:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    color: Theme.of(context).cardColor.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(12),
                    border:
                        Border.all(color: primaryColor.withValues(alpha: 0.2)),
                  ),
                  child: Row(
                    children: [
                      _buildViewModeButton(
                          'Günlük 📅', ViewMode.daily, primaryColor),
                      _buildViewModeButton(
                          'Haftalık 🗓️', ViewMode.weekly, primaryColor),
                      _buildViewModeButton(
                          'Aylık 📆', ViewMode.monthly, primaryColor),
                    ],
                  ),
                ),
                if (currentViewMode != ViewMode.monthly)
                  Container(
                    margin:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    decoration: BoxDecoration(
                      color: Theme.of(context).cardColor,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.chevron_left, size: 28),
                          onPressed: () => _changeWeek(-1),
                          tooltip: 'Önceki Hafta',
                        ),
                        GestureDetector(
                          onTap: _resetToCurrentWeek,
                          child: Column(
                            children: [
                              Text(headerTitle,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13)),
                              const SizedBox(height: 2),
                              Text('Mevcut Haftaya Dön 📍',
                                  style: TextStyle(
                                      fontSize: 10,
                                      color: primaryColor,
                                      fontWeight: FontWeight.bold)),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.chevron_right, size: 28),
                          onPressed: () => _changeWeek(1),
                          tooltip: 'Sonraki Hafta',
                        ),
                      ],
                    ),
                  ),
                Container(
                  margin:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: InkWell(
                          onTap: _showAIAnalysisModal,
                          borderRadius: BorderRadius.circular(16),
                          child: Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              gradient: isUserPremium
                                  ? LinearGradient(colors: [
                                      Colors.amber.shade900,
                                      const Color(0xFF1E293B)
                                    ])
                                  : LinearGradient(colors: [
                                      primaryColor.withValues(alpha: 0.85),
                                      primaryColor
                                    ]),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                    isUserPremium
                                        ? Icons.stars
                                        : Icons.auto_awesome,
                                    color: Colors.amber,
                                    size: 26),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    isUserPremium
                                        ? 'Weekly Intelligence VIP'
                                        : 'Akıllı Haftalık Yaşam Raporu',
                                    style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 12),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      InkWell(
                        onTap: _showSmartRebalanceDialog,
                        borderRadius: BorderRadius.circular(16),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 12),
                          decoration: BoxDecoration(
                            color: Colors.deepPurple.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                                color:
                                    Colors.deepPurple.withValues(alpha: 0.4)),
                          ),
                          child: const Row(
                            children: [
                              Icon(Icons.balance,
                                  color: Colors.deepPurple, size: 18),
                              SizedBox(width: 4),
                              Text('Dengele ⚖️',
                                  style: TextStyle(
                                      color: Colors.deepPurple,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 12)),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: _buildBodyByViewMode(primaryColor, activeModeTasks),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildViewModeButton(String title, ViewMode mode, Color primaryColor) {
    bool isSelected = currentViewMode == mode;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          setState(() {
            currentViewMode = mode;
            if (mode == ViewMode.weekly) {
              selectedDayIndex = 7;
            } else if (selectedDayIndex >= 7) {
              selectedDayIndex = DateTime.now().weekday - 1;
            }
          });
          if (mode == ViewMode.monthly) {
            _fetchAllTasksForMonth(focusedCalendarDay);
          }
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
            color: isSelected ? primaryColor : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Center(
            child: Text(
              title,
              style: TextStyle(
                color: isSelected ? Colors.white : Colors.grey,
                fontWeight: FontWeight.bold,
                fontSize: 11,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBodyByViewMode(
      Color primaryColor, Map<int, List<TaskItem>> activeTasks) {
    if (currentViewMode == ViewMode.monthly) {
      return _buildMonthlyCalendarView(primaryColor);
    } else if (currentViewMode == ViewMode.weekly) {
      return _buildAllWeekView(primaryColor, activeTasks);
    } else {
      return Column(
        children: [
          SizedBox(
            height: 80,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: 7,
              itemBuilder: (context, index) {
                bool isSelected = selectedDayIndex == index;
                DateTime dayDate = currentWeekMonday.add(Duration(days: index));

                final tasksOfDay = activeTasks[index] ?? [];
                final metrics =
                    PlanningEngine.calculatePlanningMetricsForDay(tasksOfDay);
                Color workloadColor = _getWorkloadColor(metrics.capacityUsage);

                return DragTarget<TaskItem>(
                  onAcceptWithDetails: (details) async {
                    final scaffoldMessenger = ScaffoldMessenger.of(context);
                    final result = await _moveTaskToNewDay(details.data, index);
                    if (!mounted) return;
                    if (result.isBusy) {
                      scaffoldMessenger.showSnackBar(
                        const SnackBar(
                          content:
                              Text('⏳ Görev taşıma işlemi zaten devam ediyor.'),
                          backgroundColor: Colors.blueGrey,
                        ),
                      );
                    } else if (!result.isSuccess) {
                      scaffoldMessenger.showSnackBar(
                        SnackBar(
                          content: Text(result.message ??
                              '⚠️ Görev taşındı fakat tam senkronize edilemedi.'),
                          backgroundColor: Colors.orange,
                        ),
                      );
                    }
                  },
                  builder: (context, candidateData, rejectedData) {
                    return GestureDetector(
                      onTap: () => setState(() => selectedDayIndex = index),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        width: 58,
                        margin: const EdgeInsets.only(right: 8),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? primaryColor
                              : Theme.of(context).cardColor,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                              color: isSelected
                                  ? primaryColor
                                  : Colors.grey.shade300,
                              width: isSelected ? 2 : 1),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(weekDays[index],
                                style: TextStyle(
                                    color:
                                        isSelected ? Colors.white : Colors.grey,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 12)),
                            const SizedBox(height: 2),
                            Text('${dayDate.day}',
                                style: TextStyle(
                                    color: isSelected ? Colors.white : null,
                                    fontSize: 15,
                                    fontWeight: FontWeight.bold)),
                            const SizedBox(height: 4),
                            Container(
                              width: 22,
                              height: 3.5,
                              decoration: BoxDecoration(
                                color: workloadColor,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          Expanded(child: _buildSingleDayView(primaryColor, activeTasks)),
        ],
      );
    }
  }

  Widget _buildMonthlyCalendarView(Color primaryColor) {
    final String selectedDateKey = _formatDateToKey(selectedCalendarDay);
    final List<TaskItem> tasksForSelectedDay = allMonthFetchedTasks
        .where((t) =>
            t.taskMode == activeMode && t.scheduledDate == selectedDateKey)
        .toList();

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
                color: primaryColor.withValues(alpha: 0.15), width: 1.2),
          ),
          child: TableCalendar(
            firstDay: DateTime.utc(2024, 1, 1),
            lastDay: DateTime.utc(2030, 12, 31),
            focusedDay: focusedCalendarDay,
            selectedDayPredicate: (day) => isSameDay(selectedCalendarDay, day),
            calendarFormat: CalendarFormat.month,
            startingDayOfWeek: StartingDayOfWeek.monday,
            headerStyle: HeaderStyle(
              formatButtonVisible: false,
              titleCentered: true,
              titleTextStyle: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                  color: primaryColor),
            ),
            calendarBuilders: CalendarBuilders(
              markerBuilder: (context, day, events) {
                if (events.isEmpty) {
                  return null;
                }
                return Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: events.take(4).map((event) {
                    TaskItem task = event as TaskItem;
                    return Container(
                      margin: const EdgeInsets.symmetric(horizontal: 1.5),
                      width: 5.5,
                      height: 5.5,
                      decoration: BoxDecoration(
                        color: task.taskMode == 'student'
                            ? const Color(0xFF4A55A2)
                            : const Color(0xFF1E293B),
                        shape: BoxShape.circle,
                      ),
                    );
                  }).toList(),
                );
              },
            ),
            onPageChanged: (focusedDay) {
              setState(() {
                focusedCalendarDay = focusedDay;
                selectedCalendarDay =
                    DateTime(focusedDay.year, focusedDay.month, 1);
                currentWeekMonday = selectedCalendarDay
                    .subtract(Duration(days: selectedCalendarDay.weekday - 1));
                selectedDayIndex = selectedCalendarDay.weekday - 1;
              });
              _fetchAllTasksForMonth(focusedDay);
              _fetchTasks();
            },
            onDaySelected: (selectedDay, focusedDay) {
              setState(() {
                selectedCalendarDay = selectedDay;
                focusedCalendarDay = focusedDay;
                currentWeekMonday = DateTime(
                        selectedDay.year, selectedDay.month, selectedDay.day)
                    .subtract(Duration(days: selectedDay.weekday - 1));
                selectedDayIndex = selectedDay.weekday - 1;
              });
              _fetchTasks();
            },
            eventLoader: (day) {
              final dateStr = _formatDateToKey(day);
              return allMonthFetchedTasks
                  .where((t) =>
                      t.taskMode == activeMode && t.scheduledDate == dateStr)
                  .toList();
            },
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: ListView.builder(
            itemCount: tasksForSelectedDay.length,
            itemBuilder: (context, index) {
              final task = tasksForSelectedDay[index];
              return TaskCard(
                task: task,
                primaryColor: primaryColor,
                allDayTasks: tasksForSelectedDay,
                onStatusChanged: (val) => _updateTaskCompletion(task, val),
                onEdit: () => _showEditTaskDialog(task),
                onDelete: () => _confirmDeleteTask(task),
                onRetrySync: () async {
                  final d = DateTime.tryParse(task.scheduledDate ?? '') ??
                      DateTime.now();
                  final scaffoldMessenger = ScaffoldMessenger.of(context);
                  final res = await TaskSyncCoordinator.coordinateTaskSync(
                      task: task, targetDate: d);
                  if (!mounted) {
                    return;
                  }
                  _fetchTasks();
                  final syncMsg = res.isFullySynced
                      ? '✨ Görev eşitlendi!'
                      : '⚠️ Eşitleme kısmi: ${res.effectiveUserMessage ?? 'Senkronizasyon tamamlanamadı.'}';
                  scaffoldMessenger.showSnackBar(
                    SnackBar(content: Text(syncMsg)),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildSingleDayView(
      Color primaryColor, Map<int, List<TaskItem>> activeTasks) {
    int safeIndex = (selectedDayIndex < 0 || selectedDayIndex >= 7)
        ? (DateTime.now().weekday - 1)
        : selectedDayIndex;

    final dayList = activeTasks[safeIndex] ?? [];
    final metrics = PlanningEngine.calculatePlanningMetricsForDay(dayList);
    Color scoreColor = _getWorkloadColor(metrics.capacityUsage);
    String scoreLabel = _getWorkloadLabel(metrics.capacityUsage);

    DateTime now = DateTime.now();
    DateTime dayDate = currentWeekMonday.add(Duration(days: safeIndex));
    bool isToday = (dayDate.year == now.year &&
        dayDate.month == now.month &&
        dayDate.day == now.day);

    List<TaskItem> missedTasks = [];
    if (isToday) {
      for (var t in dayList) {
        if (!t.isCompleted && t.endDateTime.isBefore(now)) {
          missedTasks.add(t);
        }
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (missedTasks.isNotEmpty)
          Container(
            padding: const EdgeInsets.all(12),
            margin: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(
              color: Colors.amber.shade50,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.amber.shade700, width: 1.2),
            ),
            child: Row(
              children: [
                const Icon(Icons.alarm_off, color: Colors.deepOrange, size: 24),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${missedTasks.length} Kaçırılan Plan Bulundu!',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                        color: Colors.deepOrange),
                  ),
                ),
                TextButton(
                  style: TextButton.styleFrom(
                      backgroundColor: Colors.amber.shade800),
                  onPressed: () async {
                    final scaffoldMessenger = ScaffoldMessenger.of(context);
                    final res = await RecoveryEngine.recoverMissedTasks(
                      missedTasks: missedTasks,
                      currentDayDate: dayDate,
                      currentWeekMonday: currentWeekMonday,
                      activeTasks: activeTasks,
                    );

                    if (!mounted) {
                      return;
                    }
                    _fetchTasks();
                    _fetchAllTasksForMonth(focusedCalendarDay);

                    List<String> outcomeParts = [];
                    if (res.successCount > 0) {
                      outcomeParts.add('${res.successCount} tam başarıyla');
                    }
                    if (res.partialSyncCount > 0) {
                      outcomeParts
                          .add('${res.partialSyncCount} kısmi eşitlemeyle');
                    }
                    if (res.skippedConflictCount > 0) {
                      outcomeParts.add(
                          '${res.skippedConflictCount} çakışma nedeniyle atlandı');
                    }
                    if (res.skippedDeadlineCount > 0) {
                      outcomeParts
                          .add('${res.skippedDeadlineCount} deadline aşımı');
                    }
                    if (res.databaseUpdateFailedCount > 0) {
                      outcomeParts.add(
                          '${res.databaseUpdateFailedCount} veritabanı hatası');
                    }
                    if (res.databaseReadFailedCount > 0) {
                      outcomeParts
                          .add('${res.databaseReadFailedCount} okuma hatası');
                    }
                    if (res.syncFailedCount > 0) {
                      outcomeParts
                          .add('${res.syncFailedCount} senkronizasyon hatası');
                    }

                    final summaryText = outcomeParts.isEmpty
                        ? 'Kurtarılacak uygun plan bulunamadı.'
                        : '⚡ Plan Kurtarma Özeti: ${outcomeParts.join(", ")}.';

                    scaffoldMessenger.showSnackBar(
                      SnackBar(content: Text(summaryText)),
                    );
                  },
                  child: const Text('Toparla ⚡',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          margin: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(
            color: scoreColor.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Kapasite Kullanımı: %${metrics.capacityUsage}',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: scoreColor)),
              Text(scoreLabel,
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: scoreColor)),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: dayList.length,
            itemBuilder: (context, index) {
              final task = dayList[index];

              return LongPressDraggable<TaskItem>(
                data: task,
                feedback: Material(
                  elevation: 6,
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    width: MediaQuery.of(context).size.width * 0.8,
                    color: primaryColor,
                    child: Text("${task.taskTime} - ${task.title}",
                        style: const TextStyle(
                            color: Colors.white, fontWeight: FontWeight.bold)),
                  ),
                ),
                childWhenDragging: Opacity(
                  opacity: 0.3,
                  child: TaskCard(
                    task: task,
                    primaryColor: primaryColor,
                    allDayTasks: dayList,
                    onStatusChanged: (val) => _updateTaskCompletion(task, val),
                    onEdit: () => _showEditTaskDialog(task),
                    onDelete: () => _confirmDeleteTask(task),
                  ),
                ),
                child: TaskCard(
                  task: task,
                  primaryColor: primaryColor,
                  allDayTasks: dayList,
                  onStatusChanged: (val) => _updateTaskCompletion(task, val),
                  onEdit: () => _showEditTaskDialog(task),
                  onDelete: () => _confirmDeleteTask(task),
                  onRetrySync: () async {
                    final d = DateTime.tryParse(task.scheduledDate ?? '') ??
                        DateTime.now();
                    final scaffoldMessenger = ScaffoldMessenger.of(context);
                    final res = await TaskSyncCoordinator.coordinateTaskSync(
                        task: task, targetDate: d);
                    if (!mounted) {
                      return;
                    }
                    _fetchTasks();
                    final syncMsg = res.isFullySynced
                        ? '✨ Görev eşitlendi!'
                        : '⚠️ Eşitleme kısmi: ${res.effectiveUserMessage ?? 'Senkronizasyon tamamlanamadı.'}';
                    scaffoldMessenger.showSnackBar(
                      SnackBar(content: Text(syncMsg)),
                    );
                  },
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildAllWeekView(
      Color primaryColor, Map<int, List<TaskItem>> activeTasks) {
    return ListView.builder(
      itemCount: 7,
      itemBuilder: (context, dayIdx) {
        final dayTasks = activeTasks[dayIdx] ?? [];
        DateTime dayDate = currentWeekMonday.add(Duration(days: dayIdx));
        final metrics = PlanningEngine.calculatePlanningMetricsForDay(dayTasks);
        Color dayColor = _getWorkloadColor(metrics.capacityUsage);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6.0),
              child: Row(
                children: [
                  Container(
                      width: 4,
                      height: 16,
                      decoration: BoxDecoration(
                          color: dayColor,
                          borderRadius: BorderRadius.circular(2))),
                  const SizedBox(width: 8),
                  Text(
                      '${fullWeekDays[dayIdx]} (${dayDate.day} ${monthNames[dayDate.month - 1]})',
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: primaryColor)),
                  const SizedBox(width: 8),
                  Text(
                      '(${dayTasks.length} Görev | Yük: %${metrics.capacityUsage})',
                      style: TextStyle(
                          fontSize: 11,
                          color: dayColor,
                          fontWeight: FontWeight.w600)),
                ],
              ),
            ),
            if (dayTasks.isEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 12.0, bottom: 8.0),
                child: Text('Plan yok',
                    style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey.shade500,
                        fontStyle: FontStyle.italic)),
              )
            else
              ...dayTasks.map((task) => TaskCard(
                    task: task,
                    primaryColor: primaryColor,
                    allDayTasks: dayTasks,
                    onStatusChanged: (val) => _updateTaskCompletion(task, val),
                    onEdit: () => _showEditTaskDialog(task),
                    onDelete: () => _confirmDeleteTask(task),
                    onRetrySync: () async {
                      final d = DateTime.tryParse(task.scheduledDate ?? '') ??
                          DateTime.now();
                      final scaffoldMessenger = ScaffoldMessenger.of(context);
                      final res = await TaskSyncCoordinator.coordinateTaskSync(
                          task: task, targetDate: d);
                      if (!mounted) {
                        return;
                      }
                      _fetchTasks();
                      final syncMsg = res.isFullySynced
                          ? '✨ Görev eşitlendi!'
                          : '⚠️ Eşitleme kısmi: ${res.effectiveUserMessage ?? 'Senkronizasyon tamamlanamadı.'}';
                      scaffoldMessenger.showSnackBar(
                        SnackBar(content: Text(syncMsg)),
                      );
                    },
                  )),
            const Divider(height: 16),
          ],
        );
      },
    );
  }
}
