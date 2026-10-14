import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'app_routes.dart';
import 'firebase_options.dart';
import 'screens/admin_dashboard_screen.dart';
import 'screens/modern_home_screen.dart';
import 'screens/manager_parking_screen.dart';
import 'theme_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await ThemeController.load();

  runApp(const KwetuParkApp());
}

class KwetuParkApp extends StatelessWidget {
  const KwetuParkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: ThemeController.mode,
      builder: (context, themeMode, _) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Kwetu Park',
        themeMode: themeMode,
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.light,
          colorSchemeSeed: const Color(0xFF006C49),
        ),
        darkTheme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          colorSchemeSeed: const Color(0xFF10B981),
        ),
        initialRoute: AppRoutes.home,
        routes: {
          AppRoutes.home: (_) => const ModernHomeScreen(),
          AppRoutes.userDashboard: (_) => const ModernHomeScreen(),
          AppRoutes.managerDashboard: (_) => const ManagerParkingScreen(),
          AppRoutes.adminDashboard: (_) => const AdminDashboardScreen(),
        },
      ),
    );
  }
}
