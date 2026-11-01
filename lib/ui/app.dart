import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app/app_state.dart';
import '../data/settings_repository.dart';
import 'library/library_screen.dart';
import 'onboarding/onboarding_screen.dart';
import 'theme.dart';

class StavelightApp extends StatelessWidget {
  const StavelightApp({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.select<AppState, (ThemePref, bool, bool)>(
        (s) => (s.settings.theme, s.settings.highContrast, s.settings.onboardingDone));
    return MaterialApp(
      title: 'Stavelight',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light, highContrast: settings.$2),
      darkTheme: buildTheme(Brightness.dark, highContrast: settings.$2),
      themeMode: switch (settings.$1) {
        ThemePref.system => ThemeMode.system,
        ThemePref.light => ThemeMode.light,
        ThemePref.dark => ThemeMode.dark,
      },
      home: settings.$3 ? const LibraryScreen() : const OnboardingScreen(),
    );
  }
}
