import 'dart:io';

import 'json_store.dart';

enum ThemePref { system, light, dark }

/// User preferences, stored as JSON next to the library.
class AppSettings {
  ThemePref theme = ThemePref.system;
  bool onboardingDone = false;
  bool noteNames = true;
  bool octaveLabels = true;
  bool fingerNumbers = true;
  bool pedalLane = true;
  bool visualEffects = true;
  bool haptics = false;
  bool audioCues = false;
  bool highContrast = false;
  double playbackVolume = 0.7;
  double metronomeVolume = 0.6;
  bool accentDownbeat = true;
  int countInBeats = 4;
  double waitTimeout = 8;
  bool streaksOptIn = false;
  int dailyGoalMinutes = 0; // 0 = no goal
  String preferredInput = 'none'; // 'midi' | 'mic' | 'none'
  String? lastMidiDevice;

  Map<String, dynamic> toJson() => {
        'theme': theme.name,
        'onboardingDone': onboardingDone,
        'noteNames': noteNames,
        'octaveLabels': octaveLabels,
        'fingerNumbers': fingerNumbers,
        'pedalLane': pedalLane,
        'visualEffects': visualEffects,
        'haptics': haptics,
        'audioCues': audioCues,
        'highContrast': highContrast,
        'playbackVolume': playbackVolume,
        'metronomeVolume': metronomeVolume,
        'accentDownbeat': accentDownbeat,
        'countInBeats': countInBeats,
        'waitTimeout': waitTimeout,
        'streaksOptIn': streaksOptIn,
        'dailyGoalMinutes': dailyGoalMinutes,
        'preferredInput': preferredInput,
        'lastMidiDevice': lastMidiDevice,
      };

  static AppSettings fromJson(Map<String, dynamic> j) {
    final s = AppSettings();
    T v<T>(String k, T d) => j[k] is T ? j[k] as T : d;
    double dv(String k, double d) => (j[k] as num?)?.toDouble() ?? d;
    return s
      ..theme = ThemePref.values.firstWhere((t) => t.name == j['theme'], orElse: () => ThemePref.system)
      ..onboardingDone = v('onboardingDone', false)
      ..noteNames = v('noteNames', true)
      ..octaveLabels = v('octaveLabels', true)
      ..fingerNumbers = v('fingerNumbers', true)
      ..pedalLane = v('pedalLane', true)
      ..visualEffects = v('visualEffects', true)
      ..haptics = v('haptics', false)
      ..audioCues = v('audioCues', false)
      ..highContrast = v('highContrast', false)
      ..playbackVolume = dv('playbackVolume', 0.7)
      ..metronomeVolume = dv('metronomeVolume', 0.6)
      ..accentDownbeat = v('accentDownbeat', true)
      ..countInBeats = v('countInBeats', 4)
      ..waitTimeout = dv('waitTimeout', 8)
      ..streaksOptIn = v('streaksOptIn', false)
      ..dailyGoalMinutes = v('dailyGoalMinutes', 0)
      ..preferredInput = v('preferredInput', 'none')
      ..lastMidiDevice = j['lastMidiDevice'] as String?;
  }
}

class SettingsRepository {
  final File file;
  SettingsRepository(Directory root) : file = File('${root.path}/settings.json');

  Future<AppSettings> load() async {
    final j = await JsonStore.read(file);
    return j == null ? AppSettings() : AppSettings.fromJson((j as Map).cast<String, dynamic>());
  }

  Future<void> save(AppSettings s) => JsonStore.write(file, s.toJson());
}
