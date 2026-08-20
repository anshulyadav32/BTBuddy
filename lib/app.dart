import 'package:flutter/material.dart';
import 'services/btbuddy_service.dart';
import 'screens/home_screen.dart';

class BTBuddyApp extends StatefulWidget {
  const BTBuddyApp({super.key});

  @override
  State<BTBuddyApp> createState() => _BTBuddyAppState();
}

class _BTBuddyAppState extends State<BTBuddyApp> {
  late final BTBuddyService service;

  @override
  void initState() {
    super.initState();
    service = BTBuddyService();
  }

  @override
  void dispose() {
    service.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ControlBuddy',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFF4F8CFF),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF0B0F17),
        cardTheme: const CardThemeData(
          color: Color(0xFF121925),
          margin: EdgeInsets.zero,
        ),
      ),
      home: HomeScreen(service: service),
    );
  }
}
