import 'dart:math' as math;
import 'dart:typed_data';

import '../model/pitch.dart';

/// One analysis frame.
class PitchFrame {
  final double time;
  final double rms;

  /// Detected fundamental in Hz, or null when there is no periodic signal.
  final double? hz;

  /// 0..1 periodicity (1 - YIN aperiodicity). Low values mean noise or overlapping notes.
  final double clarity;
  const PitchFrame({required this.time, required this.rms, this.hz, this.clarity = 0});

  double? midiFloat(double a4) => hz == null ? null : Pitch.midiFromFrequency(hz!, a4: a4);
}

/// YIN fundamental-frequency estimator (de Cheveigné & Kawahara 2002) for monophonic input.
class YinDetector {
  final int sampleRate;
  final int frameSize;
  final double minHz;
  final double maxHz;
  final double threshold;
  late final Float64List _diff;

  YinDetector({
    this.sampleRate = 22050,
    this.frameSize = 2048,
    this.minHz = 26,
    this.maxHz = 4300,
    this.threshold = 0.15,
  }) {
    _diff = Float64List(frameSize ~/ 2 + 1);
  }

  int get _tauMax => math.min(frameSize ~/ 2, (sampleRate / minHz).ceil());
  int get _tauMin => math.max(2, (sampleRate / maxHz).floor());

  static double rmsOf(Float32List x) {
    var s = 0.0;
    for (final v in x) {
      s += v * v;
    }
    return x.isEmpty ? 0 : math.sqrt(s / x.length);
  }

  PitchFrame analyze(Float32List frame, double time) {
    final rms = rmsOf(frame);
    if (frame.length < frameSize || rms < 1e-4) return PitchFrame(time: time, rms: rms);
    final tauMax = _tauMax;
    final w = frameSize - tauMax;
    // Difference function.
    for (var tau = 1; tau <= tauMax; tau++) {
      var sum = 0.0;
      for (var j = 0; j < w; j++) {
        final d = frame[j] - frame[j + tau];
        sum += d * d;
      }
      _diff[tau] = sum;
    }
    // Cumulative mean normalized difference.
    _diff[0] = 1;
    var running = 0.0;
    for (var tau = 1; tau <= tauMax; tau++) {
      running += _diff[tau];
      _diff[tau] = running == 0 ? 1 : _diff[tau] * tau / running;
    }
    // Absolute threshold: first dip below threshold, then walk to its local minimum.
    var tauEst = -1;
    for (var tau = _tauMin; tau <= tauMax; tau++) {
      if (_diff[tau] < threshold) {
        while (tau + 1 <= tauMax && _diff[tau + 1] < _diff[tau]) {
          tau++;
        }
        tauEst = tau;
        break;
      }
    }
    if (tauEst < 0) {
      // No clear dip: report best minimum with its (low) clarity.
      var best = _tauMin;
      for (var tau = _tauMin; tau <= tauMax; tau++) {
        if (_diff[tau] < _diff[best]) best = tau;
      }
      final clarity = (1 - _diff[best]).clamp(0.0, 1.0);
      if (clarity < 0.5) return PitchFrame(time: time, rms: rms, clarity: clarity);
      tauEst = best;
    }
    // Parabolic interpolation.
    var betterTau = tauEst.toDouble();
    if (tauEst > 1 && tauEst < tauMax) {
      final s0 = _diff[tauEst - 1], s1 = _diff[tauEst], s2 = _diff[tauEst + 1];
      final denom = 2 * (2 * s1 - s2 - s0);
      if (denom.abs() > 1e-12) betterTau = tauEst + (s2 - s0) / denom;
    }
    final clarity = (1 - _diff[tauEst]).clamp(0.0, 1.0);
    return PitchFrame(time: time, rms: rms, hz: sampleRate / betterTau, clarity: clarity);
  }
}

/// Converts PCM16 little-endian bytes to normalized floats.
Float32List pcm16ToFloat(Uint8List bytes) {
  final n = bytes.length ~/ 2;
  final out = Float32List(n);
  final view = ByteData.sublistView(bytes);
  for (var i = 0; i < n; i++) {
    out[i] = view.getInt16(i * 2, Endian.little) / 32768.0;
  }
  return out;
}

/// Accumulates streamed samples and yields overlapping frames.
class FrameBuffer {
  final int frameSize;
  final int hop;
  final Float32List _buf;
  int _filled = 0;
  int _consumed = 0; // total samples dropped from the front, for timing
  FrameBuffer(this.frameSize, this.hop) : _buf = Float32List(frameSize * 4);

  /// Push samples, returns (frame, startSampleIndex) for each complete frame.
  List<(Float32List, int)> push(Float32List samples) {
    final out = <(Float32List, int)>[];
    var offset = 0;
    while (offset < samples.length) {
      final take = math.min(samples.length - offset, _buf.length - _filled);
      _buf.setRange(_filled, _filled + take, samples, offset);
      _filled += take;
      offset += take;
      while (_filled >= frameSize) {
        out.add((Float32List.fromList(_buf.sublist(0, frameSize)), _consumed));
        _buf.setRange(0, _filled - hop, _buf, hop);
        _filled -= hop;
        _consumed += hop;
      }
    }
    return out;
  }
}
