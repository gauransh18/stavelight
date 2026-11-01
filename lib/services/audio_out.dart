
import 'package:flutter/foundation.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';

import '../core/audio/synth.dart';
import '../core/practice/practice_engine.dart';

/// Streams the Dart [Synth] to the speaker. Used for metronome, preview playback and accompaniment.
class AudioOut implements EngineSound {
  static const sampleRate = 44100;
  static const _chunk = 1024; // ~23 ms per feed
  final Synth synth = Synth(sampleRate: sampleRate);
  bool _ready = false;
  bool _failed = false;
  String? error;

  bool get available => _ready && !_failed;

  Future<void> init() async {
    if (_ready || _failed) return;
    try {
      await FlutterPcmSound.setup(sampleRate: sampleRate, channelCount: 1, iosAudioCategory: IosAudioCategory.playAndRecord);
      await FlutterPcmSound.setFeedThreshold(_chunk * 3);
      FlutterPcmSound.setFeedCallback(_onFeed);
      _ready = true;
      FlutterPcmSound.start();
    } catch (e) {
      _failed = true;
      error = '$e';
      debugPrint('Audio output unavailable: $e');
    }
  }

  void _onFeed(int remaining) {
    final frames = synth.render(_chunk * 2);
    FlutterPcmSound.feed(PcmArrayInt16(bytes: ByteData.sublistView(Uint8List.view(frames.buffer))));
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
    if (_ready) await FlutterPcmSound.release();
    _ready = false;
  }
}
