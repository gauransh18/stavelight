# Stavelight — Architecture & MVP Scope

Stavelight is an original piano-practice app for Android and iOS. The only songs in it are
the ones the user imports. There is no bundled catalog, no account, and data is stored locally by default.

## Stack

| Layer | Choice | Why |
|---|---|---|
| UI | Flutter 3.41 (Material 3, adaptive layouts) | One codebase for Android phones/tablets + iOS |
| State | `provider` + `ChangeNotifier` | Small surface, easy to test |
| Persistence | JSON files in app documents dir (atomic temp+rename) | Human-readable, easy backup/export, no codegen |
| File import | `file_picker` (SAF on Android, UIDocumentPicker on iOS), content sniffing | Extension filters grey out `.mid/.mxl` on some Android pickers |
| Camera | `image_picker` (camera source; permission asked by OS only when chosen) | |
| PDF raster | `pdfrx` (PDFium, on-device) | |
| Image ops / OMR | `image` (pure Dart) | On-device, no upload |
| MusicXML | `xml` + `archive` (`.mxl`) | |
| MIDI files | Hand-written SMF parser | Full control of tempo map + CC64 |
| MIDI input | `flutter_midi_command` (Android MIDI API, CoreMIDI, BLE MIDI) | |
| Microphone | `record` (PCM16 stream, never written to disk) | |
| Audio out | `flutter_pcm_sound` + own Dart synth/mixer | Low-latency metronome + preview; no sample assets |

## Module layout

```
lib/core/        Pure Dart, no Flutter imports, unit-tested
  model/         Score, ScoreNote, PedalEvent, TempoMap, Piece, PracticeSession, Calibration
  import/        format sniffer, MIDI parser, MusicXML parser, OMR engine
  edit/          ScoreEditor (command pattern, undo/redo)
  audio/         YIN pitch detector, note tracker, PCM synth
  practice/      timeline builder, matcher, practice engine (clock, wait mode, loop), stats
lib/data/        Repositories (library index, scores, sessions, settings) over dart:io
lib/services/    Thin plugin adapters: MIDI input, mic input, audio output, PDF raster
lib/ui/          Screens + CustomPainters (falling notes, keyboard, staff notation)
```

## Duration model (notation ≠ key hold ≠ sound ≠ pedal)

Each `ScoreNote` stores these as separate fields:
- `durationTicks`: the written value of this notehead (dots/tuplets applied). Tied notes stay separate noteheads joined by `tieStart`/`tieStop`.
- `holdTicks`: how long the key is expected to be held. For MIDI it comes from the real note-off. For MusicXML/OMR it is the sum of the tie chain.
- Sounding duration is derived from `holdTicks` + `PedalEvent`s and is used only for display/playback. It never changes `holdTicks`.

`PedalEvent`s (down/up, confidence, verified) are stored in their own list. They come from MIDI CC64 and MusicXML `<pedal>`/`<sound damper-pedal>`, or from user entry. A MIDI note-off is never extended because the pedal is down.

## Supported import formats

| Format | Status |
|---|---|
| MIDI `.mid/.midi` (type 0/1, tempo map, CC64, multi-track pick) | MVP |
| MusicXML `.musicxml/.xml` partwise, compressed `.mxl` | MVP (common subset) |
| PDF | MVP via raster + OMR draft |
| Images (JPG/PNG/HEIC→via picker, camera) | MVP via OMR draft |

## OMR — honest limits

No production-grade on-device OMR library exists for Flutter. Stavelight ships a **classical computer-vision draft recognizer**:
- staff lines via horizontal projection, staff spacing estimate, grand-staff pairing
- staff-line removal, barlines via vertical runs
- filled/hollow noteheads, stems, beams/flags (rough), dots, accidental *presence*, simple rests
- pitch from staff position, using a **user-confirmed** clef, key and time signature

Every recognized symbol has a confidence value and is marked *recognized* (unverified). Measures whose rhythm does not add up are flagged. Pedal "Ped."/"✱" marks are only emitted as low-confidence candidates and must be reviewed. Pages where staves cannot be found get a specific reason (resolution, skew/blur, no staves), and the user is directed to the editor for manual entry. Expect substantial manual correction on real scans, especially photos, dense piano music, multiple voices, tuplets, and grace notes. Nothing is uploaded.

## Audio/MIDI limits

- MIDI is precise (pitch, velocity, note-off, CC64 pedal). It is the recommended input.
- Microphone mode is **monophonic**: it detects one dominant pitch at a time. For chords it assesses one note and marks the rest "not assessed". Pedal is not inferred from audio. Low-confidence frames are reported as *uncertain*, never as mistakes. Audio is processed in memory and never stored.
- Tuning reference (A4, default 440 Hz) and octave offset are adjustable per input profile.

## MVP status (kept current — see README for final)

| Feature | Status |
|---|---|
| Library: search, sort, favorite, rename, duplicate, delete, re-import/replace, progress | Done |
| Local storage of originals + derived score, survives restart | Done |
| MIDI/MusicXML import, part/track pick, hand assignment, tempo changes, pickup | Done |
| Score preview + playback | Done |
| Score review editor (pitch, accidental, octave, duration, voice, hand, measure, pedal) with undo/redo + autosave | Done |
| PDF/image import, page order, rotate, crop, perspective, enhance | Done |
| OMR draft with confidence + review flags | Partial (heuristic; see limits) |
| MIDI connect + key test + transposition detect | Done (needs device to verify) |
| Mic pitch detection + octave calibration + level/noise meter | Done (needs device to verify) |
| Practice: falling notes, keyboard, sheet view, count-in, metronome, tempo, transpose | Done |
| Modes: Follow, Wait (with timeout/skip), Hands separately, Section loop, Free play, Sheet view | Done |
| Pedal lane + key-hold vs sound visuals, MIDI pedal assessment | Done |
| Session summary, per-piece history, suggestions | Done |
| Opt-in streaks, practice goal | Done |
| Practice reminders (OS notifications) | Later |
| Export/backup (zip share) + delete all data | Done (import of backup: Later) |
| AI tutor | Not included |
| Multi-voice/tuplet/grace OMR, pedal OMR beyond candidates | Later |

## Build notes

- `permission_handler` is pinned to 12.x (only `openAppSettings` is used). 13.x needs AGP 9 / Kotlin 2.3.
- `universal_ble` (Bluetooth MIDI transport) expects AGP 9's built-in Kotlin. `android/build.gradle.kts` applies the Kotlin Android plugin to that one subproject.
- The project folder was renamed from `pp's piano` to `pp-piano`, because Flutter's test runner and Xcode scripts break on an apostrophe in the path. The old name is now a symlink.

## Verification status (31 Oct 2026)

- `flutter analyze`: clean. `flutter test`: 115 passing. `flutter build apk --debug` and `flutter build ios --no-codesign` run directly in the project.
- Android debug APK builds. Smoke-tested on an Android API 36 emulator:
  - onboarding → empty library
  - document-picker import of a MIDI file → part/hand selection → review editor (note selection, editing panel) → practice (falling notes, sheet view with a moving cursor) → summary
  - the library persists after a force-stop and relaunch
  - PDF import of a synthetic grand-staff page → page editor (rotate) → recognition report → review with uncertainty badges → "Show original" crop
  - on the calibration screen, the mic is not requested until the user taps
- iOS: `flutter build ios --no-codesign` succeeds (Release, device). It hasn't been run on a simulator (no runtime installed) or a device.
- Not verified: real MIDI hardware, the microphone with a real piano, audio-output latency, and real-world scans/photos through OMR (only synthetic pages were tested).
- Podfile `post_install` raises every pod to iOS 15, because Xcode 27 rejects older targets.
