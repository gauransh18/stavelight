import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/model/calibration.dart';
import '../core/model/piece.dart';
import '../core/model/session.dart';
import '../data/library_repository.dart';
import '../data/settings_repository.dart';
import '../services/audio_out.dart';
import '../services/mic_service.dart';
import '../services/midi_service.dart';

/// App-wide state: repositories, settings, calibration profiles and input/output services.
class AppState extends ChangeNotifier {
  final LibraryRepository library;
  final SettingsRepository settingsRepo;
  AppSettings settings;
  Map<String, CalibrationProfile> calibrations;
  final MidiService midi;
  final AudioOut audio;
  MicService? _mic;

  AppState._(this.library, this.settingsRepo, this.settings, this.calibrations, this.midi, this.audio) {
    midi.addListener(_onMidiChanged);
  }

  static Future<AppState> create(Directory root) async {
    final library = LibraryRepository(root);
    await library.load();
    final settingsRepo = SettingsRepository(root);
    final settings = await settingsRepo.load();
    final calibrations = await library.loadCalibrations();
    final audio = AudioOut();
    final state = AppState._(library, settingsRepo, settings, calibrations, MidiService(), audio);
    audio.setVolumes(playback: settings.playbackVolume, metronome: settings.metronomeVolume);
    unawaited(audio.init());
    unawaited(state.midi.refresh());
    return state;
  }

  /// Created on first use; the microphone is only opened when the user picks mic input.
  MicService get mic => _mic ??= MicService(micProfile);

  CalibrationProfile get micProfile =>
      calibrations['mic'] ??= CalibrationProfile(key: 'mic', input: InputKind.mic);

  CalibrationProfile midiProfile([String? deviceName]) {
    final key = 'midi:${deviceName ?? midi.connected?.name ?? 'unknown'}';
    return calibrations[key] ??= CalibrationProfile(key: key, input: InputKind.midi);
  }

  void _onMidiChanged() {
    final d = midi.connected;
    if (d != null) {
      midi.profile = midiProfile(d.name);
      if (settings.lastMidiDevice != d.name) {
        settings.lastMidiDevice = d.name;
        unawaited(settingsRepo.save(settings));
      }
    }
  }

  /// The input practice will use: MIDI if connected (preferred), else mic if chosen, else none.
  InputKind get activeInput {
    if (midi.connected != null && settings.preferredInput != 'mic') return InputKind.midi;
    if (settings.preferredInput == 'mic') return InputKind.mic;
    if (midi.connected != null) return InputKind.midi;
    return InputKind.none;
  }

  Future<void> saveCalibration(CalibrationProfile p) async {
    p.calibratedAt = DateTime.now();
    calibrations[p.key] = p;
    if (p.input == InputKind.mic) _mic?.profile = p;
    if (p.input == InputKind.midi && p.key == 'midi:${midi.connected?.name}') midi.profile = p;
    await library.saveCalibration(p);
    notifyListeners();
  }

  Future<void> updateSettings(void Function(AppSettings s) change) async {
    change(settings);
    audio.setVolumes(playback: settings.playbackVolume, metronome: settings.metronomeVolume);
    notifyListeners();
    await settingsRepo.save(settings);
  }

  List<Piece> get pieces => library.pieces;

  /// Call after any library mutation so lists refresh.
  void libraryChanged() => notifyListeners();

  Future<void> deleteAllData() async {
    await _mic?.stop();
    midi.disconnect();
    await library.deleteAll();
    settings = AppSettings()..onboardingDone = true;
    calibrations = {};
    await settingsRepo.save(settings);
    notifyListeners();
  }

  // ---- Streaks & goals (opt-in) ----------------------------------------------------------------

  /// Consecutive days with any practice, counting back from today (or yesterday).
  static int streakFrom(List<PracticeSession> sessions, DateTime now) {
    final days = sessions.map((s) => DateTime(s.startedAt.year, s.startedAt.month, s.startedAt.day)).toSet();
    var day = DateTime(now.year, now.month, now.day);
    if (!days.contains(day)) day = day.subtract(const Duration(days: 1));
    var n = 0;
    while (days.contains(day)) {
      n++;
      day = day.subtract(const Duration(days: 1));
    }
    return n;
  }

  static int minutesOn(List<PracticeSession> sessions, DateTime day) => sessions
          .where((s) => s.startedAt.year == day.year && s.startedAt.month == day.month && s.startedAt.day == day.day)
          .fold<int>(0, (a, s) => a + s.durationSec) ~/
      60;
}
