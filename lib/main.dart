import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'core/constants.dart';
import 'data/notification_service.dart';
import 'presentation/screens/auth_screen.dart';
import 'presentation/screens/weekly_planner_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    debugPrint('🚨 [CRASH-LOG - FlutterError]: ${details.exceptionAsString()}');
    debugPrint('Stack trace: ${details.stack}');
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('🚨 [CRASH-LOG - PlatformDispatcher]: $error');
    debugPrint('Stack trace: $stack');
    return true;
  };

  // ignore: deprecated_member_use
  await Supabase.initialize(
    url: supabaseUrl,
    // ignore: deprecated_member_use
    anonKey: supabaseAnonKey,
  );

  await NotificationService.initialize();

  runApp(const WeeklyPulseApp());
}

class WeeklyPulseApp extends StatefulWidget {
  const WeeklyPulseApp({super.key});

  @override
  State<WeeklyPulseApp> createState() => _WeeklyPulseAppState();
}

class _WeeklyPulseAppState extends State<WeeklyPulseApp> {
  bool _isDark = false;
  late final Stream<AuthState> _authStream;

  @override
  void initState() {
    super.initState();
    // AUD-012: Merkezi oturum ve auth değişiklik dinleyicisi
    _authStream = supabase.auth.onAuthStateChange;
  }

  void _toggleTheme() {
    setState(() {
      _isDark = !_isDark;
    });
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AuthState>(
      stream: _authStream,
      builder: (context, snapshot) {
        final session = supabase.auth.currentSession;

        return MaterialApp(
          title: 'WeeklyPulse',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            brightness: Brightness.light,
            primaryColor: const Color(0xFF4A55A2),
            scaffoldBackgroundColor: const Color(0xFFF5F7FB),
            cardColor: Colors.white,
            colorScheme: const ColorScheme.light(
              primary: Color(0xFF4A55A2),
              secondary: Color(0xFF7895CB),
            ),
            useMaterial3: true,
          ),
          darkTheme: ThemeData(
            brightness: Brightness.dark,
            primaryColor: const Color(0xFF7895CB),
            scaffoldBackgroundColor: const Color(0xFF0F172A),
            cardColor: const Color(0xFF1E293B),
            colorScheme: const ColorScheme.dark(
              primary: Color(0xFF7895CB),
              secondary: Color(0xFFA0BFE0),
            ),
            useMaterial3: true,
          ),
          themeMode: _isDark ? ThemeMode.dark : ThemeMode.light,
          home: session != null
              ? WeeklyPlannerScreen(
                  isDark: _isDark,
                  onThemeToggle: _toggleTheme,
                )
              : AuthScreen(
                  isDark: _isDark,
                  onThemeToggle: _toggleTheme,
                ),
        );
      },
    );
  }
}
