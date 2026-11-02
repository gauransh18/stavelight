import 'dart:typed_data';

import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';

import 'pcm_sink.dart';

/// Mobile/macOS sink backed by `flutter_pcm_sound`.
///
/// This is a thin, behavior-preserving wrapper around the exact calls the
/// original `AudioOut` made, so Android/iOS/macOS output is unchanged.
class PcmSoundSink implements PcmSink {
  void Function(int remaining)? _onFeed;

  @override
  Future<void> setup({required int sampleRate, required int channelCount}) async {
    await FlutterPcmSound.setup(
      sampleRate: sampleRate,
      channelCount: channelCount,
      iosAudioCategory: IosAudioCategory.playAndRecord,
    );
  }

  @override
  void setFeedThreshold(int frames) => FlutterPcmSound.setFeedThreshold(frames);

  @override
  void setFeedCallback(void Function(int remaining) onFeed) {
    _onFeed = onFeed;
    FlutterPcmSound.setFeedCallback((remaining) => _onFeed?.call(remaining));
  }

  @override
  void feed(Int16List samples) {
    FlutterPcmSound.feed(PcmArrayInt16(bytes: ByteData.sublistView(samples)));
  }

  @override
  void start() => FlutterPcmSound.start();

  @override
  Future<void> release() => FlutterPcmSound.release();
}
