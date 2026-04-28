import 'package:flutter/material.dart';

import 'settings/app_settings.dart';
import 'ui/unlock_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = await AppSettings.load();
  runApp(StickyNotesApp(settings: settings));
}

class StickyNotesApp extends StatelessWidget {
  const StickyNotesApp({super.key, required this.settings});

  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: settings,
      builder: (context, _) {
        return MaterialApp(
          title: 'Just Notes',
          debugShowCheckedModeBanner: false,
          themeMode: settings.themeMode,
          theme: ThemeData(
            useMaterial3: true,
            brightness: Brightness.light,
            colorSchemeSeed: const Color(0xFFFFC107),
            scaffoldBackgroundColor: const Color(0xFFFAFAFA),
          ),
          darkTheme: ThemeData(
            useMaterial3: true,
            brightness: Brightness.dark,
            colorSchemeSeed: const Color(0xFFFFC107),
            scaffoldBackgroundColor: const Color(0xFF121212),
          ),
          home: UnlockScreen(settings: settings),
        );
      },
    );
  }
}
