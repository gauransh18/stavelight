import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

import '../core/audio/note_tracker.dart';
import '../core/audio/pitch_detector.dart';
import '../core/model/calibration.dart';
import '../core/practice/input_event.dart';

enum MicStatus { off, requesting, denied, listening, error }

/// Microphone pitch input. Audio is analyzed in memory frame by frame and never written to storage.
class MicService extends ChangeNotifier {
  static const sampleRate = 22050;
  AudioRecorder? _recorderInstance;
  AudioRecorder get _recorder => _recorderInstance ??= AudioRecorder();
  final YinDetector _yin = YinDetector(sampleRate: sampleRate, frameSize: 2048);
  FrameBuffer _buffer = FrameBuffer(2048, 1024);
  StreamSubscription<Uint8List>? _sub;
  late NoteTracker tracker;
  MicStatus status = MicStatus.off;
  String? error;

  double level = 0; // smoothed RMS
  double noiseEstimate = 0; // slow minimum tracker of RMS
  PitchFrame? lastFrame;
  int? currentNote;
  int _samples = 0;

  final _notes = StreamController<InputNoteEvent>.broadcast();
  final _uncertain = StreamController<InputUncertainEvent>.broadcast();
  Stream<InputNoteEvent> get notes => _notes.stream;
  Stream<InputUncertainEvent> get uncertain => _uncertain.stream;

  MicService(CalibrationProfile profile) {
    tracker = NoteTracker(profile, onNote: _onNote, onUncertain: _uncertain.add);
  }

  set profile(CalibrationProfile p) {
    tracker.profile = p;
    notifyListeners();
  }
  CalibrationProfile get profile => tracker.profile;

  bool get isListening => status == MicStatus.listening;

  /// Asks for microphone permission (only when the user chose mic input) and starts listening.
  Future<bool> start() async {
    if (isListening) return true;
    status = MicStatus.requesting;
    notifyListeners();
    try {
      if (!await _recorder.hasPermission()) {
        status = MicStatus.denied;
        notifyListeners();
        return false;
      }
      final stream = await _recorder.startStream(const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: sampleRate,
        numChannels: 1,
        autoGain: false,
        echoCancel: false,
        noiseSuppress: false,
      ));
      _buffer = FrameBuffer(2048, 1024);
      _samples = 0;
      level = 0;
      noiseEstimate = 0;
      tracker.reset();
      _sub = stream.listen(_onData, onError: (Object e) {
        error = '$e';
        status = MicStatus.error;
        notifyListeners();
      });
      status = MicStatus.listening;
      notifyListeners();
      return true;
    } catch (e) {
      error = '$e';
      status = MicStatus.error;
      notifyListeners();
      return false;
    }
  }

  void _onData(Uint8List bytes) {
    final samples = pcm16ToFloat(bytes);
    for (final (frame, start) in _buffer.push(samples)) {
      final t = (start + frame.length) / sampleRate;
      final f = _yin.analyze(frame, t);
      lastFrame = f;
      level = level * 0.6 + f.rms * 0.4;
      noiseEstimate = noiseEstimate == 0 ? f.rms : (f.rms < noiseEstimate ? f.rms : noiseEstimate * 1.002);
      tracker.process(f);
    }
    _samples += samples.length;
    notifyListeners();
  }

  void _onNote(InputNoteEvent e) {
    currentNote = e.on ? e.midi : null;
    _notes.add(e);
  }

  double get elapsed => _samples / sampleRate;

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    final r = _recorderInstance;
    if (r != null && await r.isRecording()) await r.stop();
    status = MicStatus.off;
    currentNote = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _recorderInstance?.dispose();
    _notes.close();
    _uncertain.close();
    super.dispose();
  }
}
