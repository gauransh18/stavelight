import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_midi_command/flutter_midi_command.dart';
import 'package:flutter_midi_command_ble/flutter_midi_command_ble.dart';

import '../core/model/calibration.dart';
import '../core/model/session.dart';
import '../core/practice/input_event.dart';

enum MidiStatus { idle, scanning, connecting, connected, disconnected, unavailable }

/// Parses raw MIDI bytes into note and sustain events (handles running status).
class MidiByteParser {
  int _status = 0;
  final List<int> _data = [];
  void Function(int note, int velocity, bool on)? onNote;
  void Function(bool down)? onSustain;

  void add(Uint8List bytes) {
    for (final b in bytes) {
      if (b >= 0xF8) continue; // realtime
      if (b & 0x80 != 0) {
        _status = b >= 0xF0 ? 0 : b;
        _data.clear();
        continue;
      }
      if (_status == 0) continue;
      _data.add(b);
      final type = _status & 0xF0;
      final need = (type == 0xC0 || type == 0xD0) ? 1 : 2;
      if (_data.length < need) continue;
      if (type == 0x90) {
        onNote?.call(_data[0], _data[1], _data[1] > 0);
      } else if (type == 0x80) {
        onNote?.call(_data[0], _data[1], false);
      } else if (type == 0xB0 && _data[0] == 64) {
        onSustain?.call(_data[1] >= 64);
      }
      _data.clear();
    }
  }
}

/// USB / Bluetooth MIDI keyboard input via Android MIDI API and CoreMIDI.
class MidiService extends ChangeNotifier {
  final MidiCommand _midi = MidiCommand();
  final MidiByteParser _parser = MidiByteParser();
  StreamSubscription? _rx;
  StreamSubscription? _setup;
  bool _bleConfigured = false;

  MidiStatus status = MidiStatus.idle;
  List<MidiDevice> devices = [];
  MidiDevice? connected;
  String? error;
  int? lastNote;
  int? lastRawNote;
  int lastVelocity = 0;
  bool sustainDown = false;
  final Set<int> held = {};
  CalibrationProfile? _profile;
  StreamSubscription<MidiConnectionState>? _connSub;

  CalibrationProfile? get profile => _profile;

  /// Changing the offset while keys are down would leave stale corrected notes; start clean.
  set profile(CalibrationProfile? p) {
    _profile = p;
    held.clear();
  }

  final _notes = StreamController<InputNoteEvent>.broadcast();
  final _pedal = StreamController<InputPedalEvent>.broadcast();
  Stream<InputNoteEvent> get notes => _notes.stream;
  Stream<InputPedalEvent> get pedal => _pedal.stream;

  MidiService() {
    _parser.onNote = _onNote;
    _parser.onSustain = (down) {
      sustainDown = down;
      _pedal.add(InputPedalEvent(0, down));
      notifyListeners();
    };
  }

  String get profileKey => 'midi:${connected?.name ?? 'unknown'}';

  Future<void> refresh() async {
    try {
      _setup ??= _midi.onMidiSetupChanged?.listen((_) => _onSetupChanged(), onError: (Object e) => error = '$e');
      _rx ??= _midi.onMidiPacketReceived?.listen((p) => _parser.add(p.data), onError: (Object e) => error = '$e');
      devices = (await _midi.devices) ?? [];
      if (connected != null && !devices.any((d) => d.id == connected!.id && d.connected)) {
        // Lost while we weren't looking.
        if (!devices.any((d) => d.id == connected!.id)) _markDisconnected();
      }
      if (status == MidiStatus.unavailable) status = MidiStatus.idle;
    } catch (e) {
      status = MidiStatus.unavailable;
      error = 'MIDI is not available on this device ($e)';
    }
    notifyListeners();
  }

  Future<void> _onSetupChanged() async {
    final before = connected;
    await refresh();
    if (before != null && !devices.any((d) => d.id == before.id)) _markDisconnected();
  }

  void _markDisconnected() {
    connected = null;
    held.clear();
    status = MidiStatus.disconnected;
    notifyListeners();
  }

  /// Scan for Bluetooth MIDI keyboards. The OS asks for Bluetooth permission at this point only.
  Future<void> scanBluetooth() async {
    try {
      if (!_bleConfigured) {
        _midi.configureBleTransport(UniversalBleMidiTransport());
        _bleConfigured = true;
      }
      status = MidiStatus.scanning;
      notifyListeners();
      await _midi.startBluetooth();
      await _midi.waitUntilBluetoothIsInitialized();
      await _midi.startScanningForBluetoothDevices();
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(const Duration(seconds: 1));
        await refresh();
      }
      _midi.stopScanningForBluetoothDevices();
      if (status == MidiStatus.scanning) status = connected != null ? MidiStatus.connected : MidiStatus.idle;
    } catch (e) {
      error = 'Bluetooth scan failed: $e';
      status = connected != null ? MidiStatus.connected : MidiStatus.idle;
    }
    notifyListeners();
  }

  Future<bool> connect(MidiDevice d) async {
    status = MidiStatus.connecting;
    error = null;
    notifyListeners();
    try {
      if (connected != null && connected!.id != d.id) _midi.disconnectDevice(connected!);
      await _midi.connectToDevice(d, awaitConnectionTimeout: const Duration(seconds: 15));
      connected = d;
      status = MidiStatus.connected;
      await _connSub?.cancel();
      _connSub = d.onConnectionStateChanged.listen((s) {
        if (s == MidiConnectionState.disconnected && connected?.id == d.id) _markDisconnected();
      });
      notifyListeners();
      return true;
    } catch (e) {
      error = 'Could not connect to ${d.name}: $e';
      status = MidiStatus.idle;
      notifyListeners();
      return false;
    }
  }

  void disconnect() {
    if (connected != null) _midi.disconnectDevice(connected!);
    connected = null;
    status = MidiStatus.idle;
    held.clear();
    notifyListeners();
  }

  void _onNote(int raw, int velocity, bool on) {
    final note = profile?.correct(raw) ?? raw;
    lastRawNote = raw;
    if (on) {
      lastNote = note;
      lastVelocity = velocity;
      held.add(note);
    } else {
      held.remove(note);
    }
    _notes.add(InputNoteEvent(midi: note, time: 0, on: on, confidence: 1, source: InputKind.midi, velocity: velocity));
    notifyListeners();
  }

  @override
  void dispose() {
    _rx?.cancel();
    _setup?.cancel();
    _connSub?.cancel();
    _notes.close();
    _pedal.close();
    super.dispose();
  }
}
