import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/constants.dart';
import 'data/notification_service.dart';
import 'presentation/screens/auth_screen.dart';
import 'presentation/screens/weekly_planner_screen.dart';

@pragma('vm:entry-point')
void notificationTapBackground(NotificationResponse notificationResponse) {}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. Timezone veritabanını yükle ve cihazın yerel konumunu kesinleştir
  tz_data.initializeTimeZones();
  try {
    final dynamic tzInfo = await FlutterTimezone.getLocalTimezone();
    final String timeZoneName =
        (tzInfo is String) ? tzInfo : (tzInfo.name ?? tzInfo.toString());
    tz.setLocalLocation(tz.getLocation(timeZoneName));
  } catch (e) {
    debugPrint('Cihaz saat dilimi okunamadı, varsayılan UTC atanıyor: $e');
    tz.setLocalLocation(tz.getLocation('UTC'));
  }

  await Supabase.initialize(
    url: supabaseUrl,
    // ignore: deprecated_member_use
    anonKey: supabaseAnonKey,
  );

  const AndroidInitializationSettings initializationSettingsAndroid =
      AndroidInitializationSettings('@mipmap/ic_launcher');
  const DarwinInitializationSettings initializationSettingsIOS =
      DarwinInitializationSettings(
    requestAlertPermission: true,
    requestBadgePermission: true,
    requestSoundPermission: true,
  );
  const InitializationSettings initializationSettings = InitializationSettings(
    android: initializationSettingsAndroid,
    iOS: initializationSettingsIOS,
  );

  await NotificationService.plugin.initialize(
    initializationSettings,
    onDidReceiveNotificationResponse: (NotificationResponse response) {
      if (response.payload != null && response.payload!.isNotEmpty) {
        if (onGlobalNotificationFocus != null) {
          onGlobalNotificationFocus!(response.payload!);
        } else {
          globalPendingNotificationTaskId = response.payload;
        }
      }
    },
    onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
  );

  final NotificationAppLaunchDetails? launchDetails =
      await NotificationService.plugin.getNotificationAppLaunchDetails();
  if (launchDetails != null &&
      launchDetails.didNotificationLaunchApp &&
      launchDetails.notificationResponse?.payload != null) {
    globalPendingNotificationTaskId =
        launchDetails.notificationResponse!.payload;
  }

  if (!kIsWeb && Platform.isAndroid) {
    await NotificationService.plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
  }

  final prefs = await SharedPreferences.getInstance();
  final bool initialDarkMode = prefs.getBool('is_dark_mode') ?? false;

  runApp(WeeklyPulseApp(initialDarkMode: initialDarkMode));
}

class WeeklyPulseApp extends StatefulWidget {
  final bool initialDarkMode;
  const WeeklyPulseApp({super.key, required this.initialDarkMode});

  @override
  State<WeeklyPulseApp> createState() => _WeeklyPulseAppState();
}

class _WeeklyPulseAppState extends State<WeeklyPulseApp> {
  late bool isDarkMode;

  @override
  void initState() {
    super.initState();
    isDarkMode = widget.initialDarkMode;
  }

  void toggleTheme() async {
    setState(() => isDarkMode = !isDarkMode);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('is_dark_mode', isDarkMode);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'WeeklyPulse',
      debugShowCheckedModeBanner: false,
      themeMode: isDarkMode ? ThemeMode.dark : ThemeMode.light,
      theme: ThemeData(
        brightness: Brightness.light,
        scaffoldBackgroundColor: const Color(0xFFFFFFFF),
        cardColor: const Color(0xFFF5F5F7),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          iconTheme: IconThemeData(color: Colors.black87),
          titleTextStyle: TextStyle(
              color: Colors.black87, fontSize: 18, fontWeight: FontWeight.bold),
        ),
        colorSchemeSeed: const Color(0xFF4A55A2),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF121212),
        cardColor: const Color(0xFF1E1E1E),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          iconTheme: IconThemeData(color: Colors.white),
          titleTextStyle: TextStyle(
              color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
        ),
        colorSchemeSeed: const Color(0xFF7895CB),
        useMaterial3: true,
      ),
      home: supabase.auth.currentSession == null
          ? AuthScreen(onThemeToggle: toggleTheme, isDark: isDarkMode)
          : WeeklyPlannerScreen(
              isDark: isDarkMode,
              onThemeToggle: toggleTheme,
            ),
    );
  }
}
