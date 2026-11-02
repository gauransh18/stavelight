import 'package:flutter/foundation.dart';

import '../core/audio/synth.dart';
import '../core/platform/platform_capabilities.dart';
import '../core/practice/practice_engine.dart';
import 'pcm_sink.dart';
import 'pcm_sink_pcmsound.dart';
import 'pcm_sink_desktop.dart';

/// Streams the Dart [Synth] to the speaker. Used for metronome, preview playback
/// and accompaniment.
///
/// The platform-specific output is isolated behind [PcmSink]:
///   - Android / iOS / macOS use `flutter_pcm_sound` (unchanged behavior).
///   - Windows / Linux use `flutter_soloud` because `flutter_pcm_sound` has no
///     backend there.
/// The [Synth], mixer and feed cadence are identical on every platform.
class AudioOut implements EngineSound {
  static const sampleRate = 44100;
  static const _chunk = 1024; // ~23 ms per feed
  final Synth synth = Synth(sampleRate: sampleRate);
  final PcmSink _sink = _makeSink();
  bool _ready = false;
  bool _failed = false;
  String? error;

  static PcmSink _makeSink() =>
      (PlatformCaps.isWindows || PlatformCaps.isLinux) ? DesktopPcmSink() : PcmSoundSink();

  bool get available => _ready && !_failed;

  Future<void> init() async {
    if (_ready || _failed) return;
    try {
      await _sink.setup(sampleRate: sampleRate, channelCount: 1);
      _sink.setFeedThreshold(_chunk * 3);
      _sink.setFeedCallback(_onFeed);
      _ready = true;
      _sink.start();
    } catch (e) {
      _failed = true;
      error = '$e';
      debugPrint('Audio output unavailable: $e');
    }
  }

  void _onFeed(int remaining) {
    final frames = synth.render(_chunk * 2);
    _sink.feed(frames);
  }

  void setVolumes({double? playback, double? metronome}) {
    if (playback != null) synth.masterVolume = playback;
    if (metronome != null) synth.clickVolume = metronome;
  }

  @override
  void click({required bool accent}) => synth.click(accent: accent);
  @override
  void noteOn(int midi, int velocity) => synth.noteOn(midi, velocity: velocity);
  @override
  void noteOff(int midi) => synth.noteOff(midi);
  @override
  void allOff() => synth.allOff();

  Future<void> dispose() async {
    if (_ready) await _sink.release();
    _ready = false;
  }
}
