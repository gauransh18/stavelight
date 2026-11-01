import 'dart:math' as math;
import 'dart:typed_data';

class _Voice {
  final int midi;
  final double freq;
  double amp;
  double phase = 0;
  double t = 0;
  bool released = false;
  double releaseLevel = 1;
  double releaseT = 0;
  final double decay;
  _Voice(this.midi, this.freq, this.amp, this.decay);
}

class _Click {
  final bool accent;
  double t = 0;
  _Click(this.accent);
}

/// Small additive "soft piano" synth + metronome click, rendering 16-bit mono PCM.
/// Pure Dart so it can be unit tested; an adapter streams [render] output to the device.
class Synth {
  final int sampleRate;
  final List<_Voice> _voices = [];
  final List<_Click> _clicks = [];
  double masterVolume;
  double clickVolume;
  bool sustain = false;
  static const _harmonics = [1.0, 0.45, 0.22, 0.12, 0.06];
  static const maxVoices = 24;

  Synth({this.sampleRate = 44100, this.masterVolume = 0.7, this.clickVolume = 0.6});

  int get activeVoices => _voices.length;

  void noteOn(int midi, {int velocity = 90}) {
    final freq = 440 * math.pow(2, (midi - 69) / 12).toDouble();
    final amp = (velocity.clamp(1, 127) / 127) * 0.35;
    final decay = 0.6 + (108 - midi.clamp(21, 108)) / 87 * 2.4; // low notes ring longer
    _voices.removeWhere((v) => v.midi == midi && v.released);
    if (_voices.length >= maxVoices) _voices.removeAt(0);
    _voices.add(_Voice(midi, freq, amp, decay));
  }

  void noteOff(int midi) {
    for (final v in _voices) {
      if (v.midi == midi && !v.released) {
        v.released = true;
        v.releaseLevel = _env(v);
      }
    }
  }

  void allOff() {
    for (final v in _voices) {
      if (!v.released) {
        v.released = true;
        v.releaseLevel = _env(v);
      }
    }
  }

  void click({bool accent = false}) => _clicks.add(_Click(accent));

  double _env(_Voice v) {
    final attack = (v.t / 0.006).clamp(0.0, 1.0);
    return attack * math.exp(-v.t / v.decay);
  }

  /// Render [frames] samples of mono PCM16.
  Int16List render(int frames) {
    final out = Int16List(frames);
    final dt = 1 / sampleRate;
    final releaseTime = sustain ? 2.5 : 0.18;
    for (var i = 0; i < frames; i++) {
      var s = 0.0;
      for (final v in _voices) {
        var e = _env(v);
        if (v.released) {
          e = v.releaseLevel * math.max(0, 1 - v.releaseT / releaseTime);
          v.releaseT += dt;
        }
        var h = 0.0;
        for (var k = 0; k < _harmonics.length; k++) {
          final f = v.freq * (k + 1);
          if (f > sampleRate / 2.2) break;
          h += _harmonics[k] * math.sin(v.phase * (k + 1));
        }
        s += h * v.amp * e;
        v.phase += 2 * math.pi * v.freq * dt;
        if (v.phase > 2 * math.pi * 1000) v.phase -= 2 * math.pi * 1000;
        v.t += dt;
      }
      for (final c in _clicks) {
        final f = c.accent ? 1760.0 : 1320.0;
        final e = math.exp(-c.t / 0.012);
        s += math.sin(2 * math.pi * f * c.t) * e * clickVolume * (c.accent ? 0.55 : 0.4);
        c.t += dt;
      }
      s *= masterVolume;
      s = s / (1 + s.abs()); // soft clip
      out[i] = (s * 32000).round().clamp(-32768, 32767);
    }
    _voices.removeWhere((v) => (v.released && v.releaseT >= releaseTime) || (!v.released && v.t > v.decay * 7));
    _clicks.removeWhere((c) => c.t > 0.08);
    return out;
  }
}
