import 'dart:typed_data';

/// Abstraction over a low-latency raw-PCM output sink.
///
/// This isolates the only platform-specific part of audio output — handing
/// rendered PCM bytes to the OS — so that [AudioOut], the Dart `Synth`, mixer
/// and `PracticeEngine` stay platform-agnostic and unchanged.
///
/// Two implementations exist:
///   - [PcmSoundSink]  — wraps `flutter_pcm_sound` (Android, iOS, macOS). This
///     preserves the original behavior byte-for-byte on mobile.
///   - [DesktopPcmSink] — Windows/Linux via `flutter_soloud`'s raw PCM buffer
///     stream, because `flutter_pcm_sound` has no Windows backend.
///
/// The sink is **pull-driven**: the implementation calls [onFeed] when it wants
/// more samples, and the caller feeds Int16 mono PCM via [feed]. This mirrors
/// the existing `flutter_pcm_sound` feed-callback contract so [AudioOut]'s loop
/// does not change.
abstract class PcmSink {
  /// Initialize the sink. Throws if audio output is unavailable; callers treat
  /// a throw as "no audio, run silently".
  Future<void> setup({required int sampleRate, required int channelCount});

  /// Number of frames below which [onFeed] should fire to request more data.
  void setFeedThreshold(int frames);

  /// Register the callback invoked when the sink needs more samples. The int
  /// argument is the number of frames still buffered (remaining), matching the
  /// `flutter_pcm_sound` signature.
  void setFeedCallback(void Function(int remaining) onFeed);

  /// Push Int16 (little-endian) interleaved PCM samples to the sink.
  void feed(Int16List samples);

  /// Begin playback / start the feed loop.
  void start();

  /// Stop and release all native resources.
  Future<void> release();
}
