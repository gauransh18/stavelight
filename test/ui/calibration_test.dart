import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_midi_command/flutter_midi_command.dart' show MidiDevice, MidiDeviceType;
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:stavelight/app/app_state.dart';
import 'package:stavelight/core/model/session.dart';
import 'package:stavelight/services/midi_service.dart';
import 'package:stavelight/ui/calibration/calibration_screen.dart';
import 'package:stavelight/ui/calibration/input_test_screen.dart';
import 'package:stavelight/ui/theme.dart';

const _recordChannel = MethodChannel('com.llfbandit.record/messages');

void main() {
  group('CalibrationMath', () {
    test('median ignores order and non-finite values', () {
      expect(CalibrationMath.median([]), 0);
      expect(CalibrationMath.median([3, 1, 2]), 2);
      expect(CalibrationMath.median([4, 1, 3, 2]), 2.5);
      expect(CalibrationMath.median([0.001, 0.5, 0.002, double.nan, 0.003]), closeTo(0.0025, 1e-9));
    });

    test('noise classification', () {
      expect(CalibrationMath.classifyNoise(0.001), NoiseLevel.quiet);
      expect(CalibrationMath.classifyNoise(0.008), NoiseLevel.moderate);
      expect(CalibrationMath.classifyNoise(0.05), NoiseLevel.noisy);
    });

    test('meter is log-scaled and clamped', () {
      expect(CalibrationMath.meter(0), 0);
      expect(CalibrationMath.meter(1), 1);
      expect(CalibrationMath.meter(0.001), closeTo(0, 1e-9)); // −60 dB
      expect(CalibrationMath.meter(0.0316), closeTo(0.5, 0.01)); // −30 dB
      expect(CalibrationMath.meter(5), 1);
    });

    test('nearest note and cents', () {
      final (n, c) = CalibrationMath.nearest(440);
      expect(n, 69);
      expect(c, closeTo(0, 1e-9));
      final (n2, c2) = CalibrationMath.nearest(261.63 * 1.0058); // ~ +10 cents above C4
      expect(n2, 60);
      expect(c2, closeTo(10, 0.5));
      final (n3, c3) = CalibrationMath.nearest(442, a4: 442);
      expect((n3, c3.round()), (69, 0));
      expect(CalibrationMath.centsLabel(3), 'In tune (+3 cents)');
      expect(CalibrationMath.centsLabel(-18), '−18 cents (flat)');
    });

    test('reference check outcomes', () {
      expect(CalibrationMath.checkReference(60, null, 0).outcome, ReferenceOutcome.noSignal);
      expect(CalibrationMath.checkReference(60, null, 0, sawSignal: true).outcome, ReferenceOutcome.unclear);
      expect(CalibrationMath.checkReference(60, 60, 0.4).outcome, ReferenceOutcome.unclear); // never success when unsure
      expect(CalibrationMath.checkReference(60, 60, 0.9).outcome, ReferenceOutcome.match);
      final up = CalibrationMath.checkReference(60, 72, 0.9);
      expect(up.outcome, ReferenceOutcome.octaveOff);
      expect(up.octaveDelta, 1);
      expect(up.suggestedOctaveChange, -1);
      final down = CalibrationMath.checkReference(72, 48, 0.8);
      expect(down.outcome, ReferenceOutcome.octaveOff);
      expect(down.suggestedOctaveChange, 2);
      expect(CalibrationMath.checkReference(60, 62, 0.9).outcome, ReferenceOutcome.wrongNote);
    });

    test('dominant note downgrades confidence when evidence disagrees', () {
      expect(CalibrationMath.dominant([]), isNull);
      final (m, c) = CalibrationMath.dominant([(60, 0.9), (60, 0.8)])!;
      expect((m, c), (60, 0.9));
      final (m2, c2) = CalibrationMath.dominant([(60, 0.9), (72, 0.9)])!;
      expect([60, 72], contains(m2));
      expect(c2, lessThan(CalibrationMath.minConfidence));
    });

    test('MIDI correction suggestion and labels', () {
      expect(CalibrationMath.midiCorrection(62), -2);
      expect(CalibrationMath.midiCorrection(48), 12);
      expect(CalibrationMath.midiCorrection(60), 0);
      expect(CalibrationMath.semitoneLabel(-2), '−2 semitones');
      expect(CalibrationMath.semitoneLabel(1), '+1 semitone');
      expect(CalibrationMath.semitoneLabel(12), '+1 octave');
      expect(CalibrationMath.semitoneLabel(-24), '−2 octaves');
      expect(CalibrationMath.semitoneLabel(0), '0 semitones');
    });

    test('octave hints', () {
      expect(CalibrationMath.octaveHint(60), 'middle C');
      expect(CalibrationMath.octaveHint(72), 'one octave above middle C');
      expect(CalibrationMath.octaveHint(36), '2 octaves below middle C');
      expect(CalibrationMath.octaveHint(64), 'octave 4');
    });
  });

  group('KeyWindow', () {
    test('stays put inside the window and shifts minimally outside', () {
      expect(KeyWindow.follow(48, 84, 60), (48, 84));
      expect(KeyWindow.follow(48, 84, 90), (56, 92));
      expect(KeyWindow.follow(48, 84, 40), (38, 74));
    });
    test('alternating notes stop moving the window after the first shift', () {
      var w = (48, 84);
      final seen = <(int, int)>{};
      for (var i = 0; i < 6; i++) {
        w = KeyWindow.follow(w.$1, w.$2, i.isEven ? 49 : 71);
        if (i > 0) seen.add(w);
      }
      expect(seen, hasLength(1));
    });
    test('clamps to the 88-key range', () {
      expect(KeyWindow.follow(48, 84, 21), (21, 57));
      expect(KeyWindow.follow(48, 84, 108), (72, 108));
    });
  });

  group('screens', () {
    late Directory dir;
    late List<MethodCall> recordCalls;
    late bool micAllowed;
    MockStreamHandlerEventSink? audioSink;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('sl_calib');
      recordCalls = [];
      micAllowed = false;
      audioSink = null;
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(_recordChannel, (call) async {
        recordCalls.add(call);
        if (call.method == 'startStream') {
          final id = (call.arguments as Map)['recorderId'];
          messenger.setMockStreamHandler(
            EventChannel('com.llfbandit.record/eventsRecord/$id'),
            MockStreamHandler.inline(
              onListen: (_, sink) {
                audioSink = sink;
              },
            ),
          );
          messenger.setMockStreamHandler(EventChannel('com.llfbandit.record/events/$id'), MockStreamHandler.inline(onListen: (_, _) {}));
        }
        return switch (call.method) {
          'hasPermission' => micAllowed,
          'isRecording' || 'isPaused' => false,
          _ => null,
        };
      });
    });
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_recordChannel, null);
      dir.deleteSync(recursive: true);
    });

    Future<AppState> createState(WidgetTester tester) async {
      final s = await tester.runAsync(() async {
        final s = await AppState.create(dir);
        await Future<void>.delayed(const Duration(milliseconds: 200)); // let unawaited plugin calls settle
        return s;
      });
      return s!;
    }

    Future<void> pump(WidgetTester tester, AppState state, Widget child) async {
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: MaterialApp(theme: buildTheme(Brightness.light), home: child),
        ),
      );
      await tester.pump();
    }

    testWidgets('MIDI tab shows unavailable / no-devices state without crashing', (tester) async {
      final state = await createState(tester);
      await pump(tester, state, const CalibrationScreen(initialInput: InputKind.midi));
      expect(tester.takeException(), isNull);
      expect(find.text('MIDI keyboard'), findsWidgets);
      expect(find.textContaining('No MIDI devices found'), findsOneWidget);
      expect(find.textContaining('MIDI isn’t available'), findsOneWidget);
      expect(find.text('Scan for Bluetooth MIDI'), findsOneWidget);
      // No device → no key test that could save a "midi:unknown" profile.
      expect(find.text('Start key test'), findsNothing);
      await tester.ensureVisible(find.text('Refresh'));
      await tester.pump();
      await tester.tap(find.text('Refresh'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('connected keyboard shows live input, key test and manual correction', (tester) async {
      final state = await createState(tester);
      tester.view
        ..physicalSize = const Size(800, 3200)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final d = MidiDevice('1', 'Test Piano', MidiDeviceType.serial, true);
      state.midi
        ..devices = [d]
        ..connected = d
        ..status = MidiStatus.connected
        ..error = null;
      await pump(tester, state, const CalibrationScreen(initialInput: InputKind.midi));
      expect(find.text('MIDI · Test Piano'), findsOneWidget);
      expect(find.text('Disconnect'), findsOneWidget);
      expect(find.text('Pedal up'), findsOneWidget);
      expect(find.textContaining('Press middle C'), findsOneWidget);

      final start = find.text('Start key test');
      await tester.ensureVisible(start);
      await tester.pump();
      await tester.tap(start);
      await tester.pump();
      expect(find.text('Waiting for a key…'), findsOneWidget);

      final raise = find.byTooltip('Raise octave');
      await tester.ensureVisible(raise);
      await tester.pump();
      await tester.tap(raise);
      await tester.pump();
      expect(state.calibrations['midi:Test Piano']!.octaveOffset, 1);
      expect(state.calibrations['midi:Test Piano']!.confirmed, isTrue);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    });

    testWidgets('mic tab explains privacy and only starts the mic on tap', (tester) async {
      final state = await createState(tester);
      await pump(tester, state, const CalibrationScreen(initialInput: InputKind.mic));
      expect(find.textContaining('never recorded, saved or uploaded'), findsOneWidget);
      expect(find.text('Quiet room'), findsOneWidget);
      expect(find.text('No pedal during calibration'), findsOneWidget);
      expect(recordCalls, isEmpty, reason: 'the recorder must not be touched before the user taps start');

      final start = find.text('Start microphone check');
      await tester.ensureVisible(start);
      await tester.pump();
      await tester.tap(start);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
      expect(recordCalls.map((c) => c.method), contains('hasPermission'));
      // Mock denies permission → settings + MIDI fallback.
      expect(find.text('Open settings'), findsOneWidget);
      expect(find.text('Use MIDI instead'), findsWidgets);

      await tester.tap(find.text('Use MIDI instead').first);
      await tester.pump();
      expect(find.text('Scan for Bluetooth MIDI'), findsOneWidget);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    });

    testWidgets('mic calibration: noise check, unclear note is never success, C4 + C5 confirm and save', (tester) async {
      final state = await createState(tester);
      micAllowed = true;
      tester.view
        ..physicalSize = const Size(800, 3200)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      // Feeds [seconds] of PCM16 audio (sine at [hz], or silence) in 100 ms chunks.
      Future<void> feed(double seconds, {double? hz}) async {
        const sr = 22050, chunk = 2205;
        var phase = 0.0;
        for (var i = 0; i < (seconds * 10).round(); i++) {
          final bytes = ByteData(chunk * 2);
          for (var j = 0; j < chunk; j++) {
            final v = hz == null ? 0.0 : 0.4 * math.sin(phase);
            phase += 2 * math.pi * (hz ?? 0) / sr;
            bytes.setInt16(j * 2, (v * 32767).round(), Endian.little);
          }
          audioSink?.success(bytes.buffer.asUint8List());
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      await pump(tester, state, const CalibrationScreen(initialInput: InputKind.mic));
      await tester.tap(find.text('Start microphone check'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
      expect(audioSink, isNotNull);
      expect(find.text('Stay quiet for a moment'), findsOneWidget);

      await feed(3.2);
      expect(find.text('Room measured'), findsOneWidget);
      expect(find.text('Quiet room — good for detection.'), findsOneWidget);
      await tester.tap(find.text('Continue'));
      await tester.pump();
      expect(find.text('Play middle C (C4)'), findsOneWidget);

      // Silence → honest failure, never a success prompt.
      await feed(8.5);
      expect(find.text("Couldn't hear a clear note"), findsOneWidget);
      expect(find.text('Yes'), findsNothing);

      // Octave adjust changes the profile and immediately retests.
      await tester.tap(find.byTooltip('Raise octave'));
      await tester.pump();
      expect(state.mic.profile.octaveOffset, 1);
      expect(find.text('Listening…'), findsWidgets);
      await tester.tap(find.byTooltip('Lower octave'));
      await tester.pump();
      expect(state.mic.profile.octaveOffset, 0);

      await feed(0.5);
      await feed(1.5, hz: 261.63);
      expect(find.text('Heard C4'), findsOneWidget);
      expect(find.text('Is this the note you played?'), findsOneWidget);
      await tester.tap(find.text('Yes'));
      await tester.pump();
      expect(find.text('Play C5 (one octave higher)'), findsOneWidget);

      await feed(0.6);
      await feed(1.5, hz: 523.25);
      expect(find.text('Heard C5'), findsOneWidget);
      await tester.tap(find.text('Yes'));
      // Saving does real file I/O across several awaits: alternate real time and frames.
      for (var i = 0; i < 20 && find.text('Calibrated').evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump();
      }
      expect(find.text('Calibrated'), findsOneWidget);
      expect(state.calibrations['mic']!.confirmed, isTrue);
      expect(state.calibrations['mic']!.octaveOffset, 0);
      expect(state.settings.preferredInput, 'mic');

      await tester.pumpWidget(const SizedBox()); // dispose → mic stops
      for (var i = 0; i < 10 && state.mic.isListening; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
      expect(state.mic.isListening, isFalse);
      expect(recordCalls.map((c) => c.method), contains('isRecording')); // MicService.stop() ran
    });

    testWidgets('large text, dark theme and landscape render without overflow', (tester) async {
      final state = await createState(tester);
      tester.view
        ..physicalSize = const Size(700, 360)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final d = MidiDevice('1', 'A keyboard with a rather long device name', MidiDeviceType.ble, true);
      state.midi
        ..devices = [d]
        ..connected = d
        ..status = MidiStatus.connected;
      for (final screen in const [
        CalibrationScreen(initialInput: InputKind.midi),
        CalibrationScreen(initialInput: InputKind.mic),
        InputTestScreen(diagnostics: true),
      ]) {
        await tester.pumpWidget(
          ChangeNotifierProvider<AppState>.value(
            value: state,
            child: MaterialApp(
              theme: buildTheme(Brightness.dark),
              builder: (c, child) => MediaQuery(
                data: MediaQuery.of(c).copyWith(textScaler: const TextScaler.linear(2)),
                child: child!,
              ),
              home: screen,
            ),
          ),
        );
        await tester.pump();
        // Scroll through the whole list so every section lays out.
        final list = find.byType(Scrollable).first;
        for (var i = 0; i < 12; i++) {
          await tester.drag(list, const Offset(0, -300));
          await tester.pump();
        }
        expect(tester.takeException(), isNull);
      }
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    });

    testWidgets('diagnostics screen says nothing is scored and prompts for an input', (tester) async {
      final state = await createState(tester);
      await pump(tester, state, const InputTestScreen(diagnostics: true));
      expect(find.textContaining('Nothing is scored here'), findsOneWidget);
      expect(find.text('Input diagnostics'), findsOneWidget);
      expect(find.text('No input selected'), findsOneWidget);
      expect(find.text('Connect a MIDI keyboard'), findsOneWidget);
      expect(recordCalls, isEmpty);
    });

    testWidgets('free play with mic preferred waits for a tap before listening', (tester) async {
      final state = await createState(tester);
      state.settings.preferredInput = 'mic';
      await pump(tester, state, const InputTestScreen());
      expect(find.text('Free play'), findsOneWidget);
      expect(find.textContaining('Nothing is scored here'), findsOneWidget);
      expect(find.text('Start listening'), findsWidgets);
      expect(recordCalls, isEmpty);
      await tester.tap(find.widgetWithText(FilledButton, 'Start listening'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
      expect(find.text('Open settings'), findsOneWidget);
    });
  });
}
