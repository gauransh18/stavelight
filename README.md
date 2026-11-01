# Stavelight

Stavelight is a piano practice app for Android and iOS that works with **your own sheet music**. You import a PDF, a photo or scan, a MusicXML file or a MIDI file. You review the notes it finds, then practice with falling notes or sheet music while the app listens through a MIDI keyboard or the microphone.

- No song catalog is bundled. Your imports are the library.
- No account is needed. Files, scores, practice history and calibration are stored on the device.
- Scan recognition runs on the device. Microphone audio is analyzed in memory and never saved or uploaded.

The architecture, the library choices, and an honest table of what is done versus deferred are in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Build & run

Requirements: Flutter 3.41+ (Dart 3.11), Android SDK 36 with accepted licenses, and Xcode for iOS.

The project lives in `~/Dev/pp-piano`. `~/Dev/pp's piano` is a symlink to it, kept for compatibility. Flutter resolves the real path, so the apostrophe no longer breaks its tooling.

```bash
flutter pub get
flutter run                 # connected Android device / emulator or iOS simulator
flutter build apk --debug   # Android
flutter build ios --no-codesign
flutter test
flutter analyze
```

If Android builds fail on licenses, accept them once:

```bash
flutter doctor --android-licenses
```

### Platform notes
- **Android:** `minSdk 24`.
  - Permissions: microphone, plus Bluetooth scan/connect for BLE MIDI. Each is requested only when you use that feature.
  - There is no CAMERA permission, because photos go through the system camera app.
  - USB MIDI keyboards need an OTG adapter.
- **iOS:** deployment target 15.0. Usage strings for the microphone, camera, photo library and Bluetooth are in `Info.plist`.
  - USB MIDI works through CoreMIDI (Camera Connection Kit or USB-C).
  - Bluetooth MIDI pairing uses the in-app scan.

## Using it

1. **Import.** Tap *Import sheet music* and choose a file, photograph pages, or pick photos. Files are identified by their content, so `.mid` and `.mxl` work even when the picker doesn't recognise the extension.
2. **Review.**
   - *MIDI/MusicXML:* pick the parts or tracks to practise and assign hands.
   - *PDF/photos:*
     1. Order, rotate, crop, straighten and enhance the pages.
     2. Confirm the clef, key, time signature and tempo. The app never guesses these silently.
     3. Run recognition and read the per-page report.
   - In the editor, tap any note or measure to fix it: pitch, accidental, octave, duration, voice, hand, barlines, time or key signature, and pedal marks. Undo and redo are available, and edits autosave.
   - Uncertain items carry a **?** badge until you verify them.
3. **Calibrate.** Open the toolbar's tune icon. With a MIDI keyboard, press middle C to detect a transposed keyboard. With the microphone, run a noise check, play C4 and then C5, and confirm or shift the octave. You can also adjust the tuning reference (A4).
4. **Practice.**
   - Modes: *Follow along* or *Wait for me*.
   - Options: both hands or one hand (the other can play for you), tempo 25–150%, metronome and count-in, a section loop, transposition, and falling-notes or sheet view.
   - While playing you get feedback such as *Correct*, *Early*, *Late*, *Octave too high*, *Try again*, *Not sure what was played* or *Input too noisy*.
5. **Summary.** See time practised, measures played, pitch and timing estimates, the notes and measures that slipped most, and a one-tap suggested next step. Per-piece history is in the library card menu.

## Test plan

Automated tests are in `test/`. Run them with `flutter test`.

| Area | Tests |
|---|---|
| Acceptance | `test/acceptance_test.dart`: MIDI import → library → restart → octave fix with undo → Wait-mode practice → progress saved. Also checks that MusicXML dotted and tied notes are durations, not pedal. |
| Import | `test/core/import/`: MIDI (format 0/1, running status, tempo map, PPQ rescale, CC64 kept separate from durations), MusicXML (dots, ties, chords, voices, pedal, pickup, `.mxl`), track selection, and OMR on synthetic pages (pitches, durations, chords, rhythm flags, key signatures, and failure reasons for blank, tiny and tilted pages). |
| Practice | `test/core/practice/`: timeline/hands/transpose, matcher outcomes (MIDI + mic), the rule that low confidence is never scored as a mistake, mic chords marked "not assessed", early key release, pedal timing, Wait mode with skip, tempo scaling, loop accumulation, suggestions. |
| Audio | `test/core/audio/`: YIN pitch on harmonic tones and tuning reference, noise rejection, note tracker with octave calibration, synth. |
| Data | `test/data/`: persistence across restart, rename/duplicate/delete/search, progress (ignores low-quality sessions), backup zip, delete-all. |
| UI | `test/ui/`: staff layout and hit-testing, review editor edits with undo, calibration and diagnostics screens. |

Manual checks need a real device:
1. **Imports.** Import a MIDI file, a MusicXML file, a phone photo of a page, and a multi-page PDF. Restart the app and confirm all are listed.
2. **Recognition.** Photo with poor light: expect a clear failure reason or many **?** marks, never silent practice data. Fix one note's octave and verify it.
3. **MIDI keyboard.**
   1. Connect it over USB.
   2. Run the key test.
   3. Practise in Wait mode: the cursor must stop until the chord is played, and Skip appears after the timeout.
   4. Unplug mid-session: practice should pause with a banner.
4. **Microphone.**
   1. Calibrate.
   2. Practise slowly: confirm wrong-octave detection is reported as an octave issue, and noisy moments as "unclear".
   3. Deny mic permission: expect an explanation and a link to Settings.
5. **Practice controls.** Tempo 50%, a loop of measures 2–3, right hand only, transpose +2: confirm the expected notes and the playback follow each.
6. **Interruptions.** Rotate, background the app mid-session, and resume: your place is kept. Turn on TalkBack/VoiceOver and large text.

## Known limitations

- **Scan recognition is a heuristic draft.** It handles common single-voice piano notation with clean staves. It does *not* handle ties, slurs, tuplets, grace notes, multiple voices per staff, mid-piece clef or key changes, or dewarping of curved photos. Pedal marks only become low-confidence candidates. Expect to correct real scans. Everything stays marked "recognized" until you verify it.
- **The microphone is monophonic.** It detects one dominant pitch. Chord notes other than the one heard are "not assessed". Pedal and exact note-off can't be detected from audio. Timing is approximate (about 50–90 ms of analysis latency is not compensated).
- **MIDI pedal and key-release assessment** need a keyboard that sends CC64 and note-off.
- **Repeats** in MusicXML are played straight through, not unrolled.
- **Not implemented yet:** OS practice reminders (the goal/streak display is in-app only), restoring from a backup zip (export only), and an AI tutor.
- **Verified in this environment:**
  - Android debug APK, smoke-tested on an emulator: MIDI import and practice, PDF import → recognition → review, sheet view, and persistence across restart.
  - The iOS Release build compiles, signs and launches on an iPhone 15 (iOS 27). Features beyond launch were not exercised on the phone.
- **Not verified:**
  - iOS features on a device: import, practice, mic, MIDI.
  - Real MIDI keyboards, the microphone with a real piano, and audio latency.
  - Real-world scans: only synthetic pages were run through recognition.

## License

MIT. See [LICENSE](LICENSE).
