import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_soloud/flutter_soloud.dart';

import 'pcm_sink.dart';

/// Desktop (Windows/Linux) sink backed by `flutter_soloud`'s raw-PCM buffer
/// stream, because `flutter_pcm_sound` has no Windows/Linux backend.
///
/// `flutter_soloud` is self-paced (it consumes the pushed buffer at the sample
/// rate). To reproduce the pull-style contract that [AudioOut] expects, a
/// periodic [Timer] ticks faster than real time, asks the registered feed
/// callback for more samples, and pushes whatever Int16 PCM it produces into
/// the stream. A small amount of lead buffer is maintained so the engine never
/// starves.
class DesktopPcmSink implements PcmSink {
  SoLoud get _soloud => SoLoud.instance;

  AudioSource? _stream;
  Timer? _timer;

  int _sampleRate = 44100;
  int _channels = 1;
  int _thresholdFrames = 1024 * 3;
  void Function(int remaining)? _onFeed;

  // Rough running estimate of how many frames are still buffered ahead of the
  // play head. Updated as we push (and decremented by wall-clock consumption).
  double _bufferedFrames = 0;
  DateTime _lastTick = DateTime.now();

  bool _released = false;

  @override
  Future<void> setup({required int sampleRate, required int channelCount}) async {
    _sampleRate = sampleRate;
    _channels = channelCount;
    // init() is safe to call once; if the engine is already up (e.g. hot
    // restart) it throws, which we swallow since we only need it running.
    try {
      await _soloud.init(sampleRate: sampleRate, channels: channelCount == 1 ? Channels.mono : Channels.stereo);
    } catch (_) {
      // Already initialized or init raced; proceed to create the stream.
    }
    _stream = _soloud.setBufferStream(
      // ~5 s ceiling; released frees played data so memory stays bounded.
      maxBufferSizeBytes: sampleRate * channelCount * 2 * 5,
      bufferingType: BufferingType.released,
      bufferingTimeNeeds: 0.05,
      sampleRate: sampleRate,
      channels: channelCount == 1 ? Channels.mono : Channels.stereo,
      format: BufferType.s16le,
    );
  }

  @override
  void setFeedThreshold(int frames) => _thresholdFrames = frames;

  @override
  void setFeedCallback(void Function(int remaining) onFeed) => _onFeed = onFeed;

  @override
  void feed(Int16List samples) {
    final stream = _stream;
    if (stream == null || _released) return;
    _soloud.addAudioDataStream(stream, samples.buffer.asUint8List(samples.offsetInBytes, samples.lengthInBytes));
    _bufferedFrames += samples.length / _channels;
  }

  @override
  void start() {
    final stream = _stream;
    if (stream == null) return;
    // Prime the buffer before playback so it doesn't immediately starve.
    _onFeed?.call(0);
    try {
      _soloud.play(stream);
    } catch (_) {
      // If playback fails to start, the feed loop below is harmless.
    }
    _lastTick = DateTime.now();
    // Tick ~every 10 ms; decrement the buffer estimate by elapsed wall time and
    // top it up through the feed callback when it drops below the threshold.
    _timer = Timer.periodic(const Duration(milliseconds: 10), (_) {
      if (_released) return;
      final now = DateTime.now();
      final elapsedSec = now.difference(_lastTick).inMicroseconds / 1e6;
      _lastTick = now;
      _bufferedFrames -= elapsedSec * _sampleRate;
      if (_bufferedFrames < 0) _bufferedFrames = 0;
      final remaining = _bufferedFrames.round();
      if (remaining < _thresholdFrames) _onFeed?.call(remaining);
    });
  }

  @override
  Future<void> release() async {
    _released = true;
    _timer?.cancel();
    _timer = null;
    final stream = _stream;
    _stream = null;
    if (stream != null) {
      try {
        _soloud.setDataIsEnded(stream);
        await _soloud.disposeSource(stream);
      } catch (_) {
        // best effort
      }
    }
  }
}
