# Requirements — Windows Support for Stavelight

## Introduction

Stavelight is a Flutter piano-practice app currently targeting Android and iOS only (the repo has `android/` and `ios/` platform folders, no `windows/`). The goal of this feature is to make the app build and run on Windows as a native desktop app with **exactly the same functionality it has today**, with special attention to connecting a MIDI keyboard over a USB-B (device) to USB-A (host PC) cable, scanning for that device, and reading its note/pedal input.

No feature is to be removed, renamed, or redesigned. This is a compatibility port: add the Windows platform, make every existing capability work (or degrade honestly and visibly where a dependency has no Windows implementation), and keep Android/iOS behavior unchanged.

### Source facts established during investigation
- Flutter app, `pubspec.yaml` SDK `^3.11.5`, state via `provider`/`ChangeNotifier`.
- MIDI input is in `lib/services/midi_service.dart` using `flutter_midi_command ^1.0.3` (+ `flutter_midi_command_ble ^1.4.0` for BLE).
- `flutter_midi_command 1.x` **does support Windows USB MIDI** (wraps win32/WinMM; native USB MIDI hot-plug monitoring; multi-port WinMM endpoints paired into full-duplex devices). BLE MIDI is **not** supported on Windows by this plugin.
- Audio output is in `lib/services/audio_out.dart` using `flutter_pcm_sound ^3.3.3`, which **does NOT support Windows** (Flutter/Android/iOS/macOS only). This is the primary blocker.
- Microphone input is in `lib/services/mic_service.dart` using `record ^6.2.1`, which supports Windows.
- Storage root comes from `path_provider` `getApplicationDocumentsDirectory()` in `lib/main.dart`; file I/O in `lib/data/library_repository.dart` already uses `Platform.pathSeparator` in one place but hardcodes `/` in path construction elsewhere.
- No `Platform.is*` branching exists anywhere in `lib/` today.
- Other plugins whose Windows support must be verified: `file_picker`, `pdfrx`, `permission_handler`, `image_picker`, `wakelock_plus`, `share_plus`, `shared_preferences`, `image`, `archive`, `xml`, `uuid`.
- **Flutter is not currently on PATH in the build environment**, so automated `flutter` verification may not be possible; this is tracked as a risk.

## Glossary
- **Host MIDI / WinMM**: the Windows multimedia MIDI API that `flutter_midi_command` uses on Windows. A class-compliant USB MIDI keyboard appears here automatically via the Windows USB-audio/MIDI driver — no vendor driver needed.
- **USB-B→USB-A cable**: the standard "printer style" USB MIDI cable; the keyboard is the USB device (USB-B port on the keyboard) and the PC is the USB host (USB-A port). On the PC this surfaces as a standard MIDI input port.
- **Honest degradation**: where a capability has no Windows implementation in its current plugin, the app must show a clear, user-visible message and disable only that capability, never crash or silently no-op.

---

## Requirement 1 — Windows build target exists and compiles

**User story:** As a Windows user, I want Stavelight to build and launch as a native Windows desktop app, so that I can run it on my PC.

#### Acceptance Criteria
1. WHEN the Windows platform folder is generated (`flutter create --platforms=windows .`) THEN the repo SHALL contain a `windows/` directory with the standard runner, CMake, and plugin registrant files.
2. WHEN `flutter config --enable-windows-desktop` is active AND `flutter build windows` is run THEN the build SHALL complete without errors and produce a runnable `.exe` under `build/windows/`.
3. WHEN the app launches on Windows THEN it SHALL show the same onboarding/empty-library flow as Android/iOS.
4. IF Flutter tooling is unavailable in the current environment THEN the spec SHALL record the exact commands and expected outputs so a maintainer can run them, and the code SHALL be written so it is build-ready.
5. The Windows app SHALL declare an appropriate app name, window title "Stavelight", and a sensible default window size.
6. Android and iOS builds SHALL remain unchanged and continue to build (`flutter build apk --debug`, `flutter build ios --no-codesign`).

## Requirement 2 — Storage and file paths are Windows-correct

**User story:** As a Windows user, I want my library, scores, sessions, and calibration to persist on disk exactly like on mobile, so that nothing is lost between launches.

#### Acceptance Criteria
1. WHEN the app starts on Windows THEN it SHALL resolve a per-user writable app-data directory via `path_provider` and store everything under a `stavelight` subfolder, equivalent to the mobile behavior.
2. WHEN files are read or written THEN path construction SHALL work with Windows path separators (no hardcoded `/` assumptions that break on Windows) while remaining correct on Android/iOS.
3. WHEN a piece is added, duplicated, replaced, deleted, or a backup zip is exported THEN all resulting file paths SHALL be valid on Windows and round-trip correctly.
4. WHEN the app is force-closed and relaunched on Windows THEN the library, scores, sessions, calibration, and settings SHALL persist (parity with the mobile "survives restart" guarantee).
5. The backup zip entries SHALL use forward-slash relative paths (zip standard) regardless of host OS.

## Requirement 3 — USB MIDI keyboard: scan, connect, read input on Windows

**User story:** As a Windows user, I connect my MIDI keyboard to the PC with a USB-B→USB-A cable, and I want the app to find it, connect, and read the keys and sustain pedal exactly like on mobile.

#### Acceptance Criteria
1. WHEN a class-compliant USB MIDI keyboard is connected to the PC over USB-B→USB-A THEN the app's device scan (`MidiService.refresh()`) SHALL list it as an available MIDI input device on Windows.
2. WHEN the user selects the device THEN `MidiService.connect()` SHALL connect through the Windows host MIDI (WinMM) backend and set status to `connected`.
3. WHEN keys are pressed/released on the keyboard THEN note-on/note-off events SHALL be parsed (including running status) and surfaced through the existing `notes` stream with correct MIDI note numbers and velocities, identical to mobile.
4. WHEN the sustain pedal (CC64) is pressed/released THEN pedal down/up events SHALL be surfaced through the existing `pedal` stream.
5. WHEN the keyboard is unplugged mid-session THEN the app SHALL detect the removal (via setup-change monitoring) and transition to `disconnected`, matching mobile behavior (practice pauses with a banner).
6. WHEN the keyboard is hot-plugged while the app is open THEN it SHALL appear in the device list without needing an app restart (relying on the plugin's Windows USB hot-plug monitoring).
7. The calibration flow (press middle C to detect transposition, transpose offset applied via `CalibrationProfile.correct`) SHALL work unchanged with a Windows-connected keyboard.
8. IF MIDI is unavailable on the host THEN the status SHALL become `unavailable` with a clear message, never a crash (parity with existing error handling).

## Requirement 4 — Bluetooth MIDI degrades honestly on Windows

**User story:** As a Windows user without Windows BLE-MIDI support in the plugin, I want the app to make clear that Bluetooth MIDI is unavailable on Windows rather than appear broken.

#### Acceptance Criteria
1. WHEN the app runs on Windows THEN it SHALL NOT attempt to configure/start the BLE transport if the plugin does not support BLE MIDI on Windows.
2. WHEN the user looks for a MIDI connection method on Windows THEN the Bluetooth-scan affordance SHALL be hidden or disabled with a short explanation that BLE MIDI is not available on Windows and USB is the supported path.
3. Android/iOS BLE MIDI behavior SHALL remain unchanged.
4. No code path SHALL throw an unhandled `StateError`/exception on Windows because a BLE-only call was made.

## Requirement 5 — Audio output works on Windows (metronome, playback, count-in, accompaniment)

**User story:** As a Windows user, I want the metronome, note preview, count-in, and "play the other hand for me" accompaniment to be audible, exactly like on mobile.

#### Acceptance Criteria
1. WHEN practice uses the metronome, count-in, playback preview, or accompaniment THEN audio SHALL be produced on Windows with the same Dart `Synth`/mixer output currently feeding `flutter_pcm_sound`.
2. BECAUSE `flutter_pcm_sound` has no Windows implementation, the design SHALL provide a Windows-capable PCM output path behind the existing `AudioOut`/`EngineSound` interface, WITHOUT changing the `Synth` or `PracticeEngine`.
3. WHEN audio output initialization fails on Windows THEN the app SHALL set the existing `available=false`/error state and continue to run (silent), exactly as the current `AudioOut.init()` failure path does — no crash.
4. The audio output change SHALL NOT alter Android/iOS behavior (same plugin and code path there).
5. Latency SHALL be acceptable for a metronome and preview (target comparable to the current ~23 ms chunking); exact figure is best-effort and noted as not independently verified without hardware.

## Requirement 6 — Microphone input works on Windows

**User story:** As a Windows user, I want microphone pitch detection and calibration to work like on mobile.

#### Acceptance Criteria
1. WHEN the user chooses mic input on Windows THEN `record` SHALL request microphone permission (or rely on OS behavior) and stream PCM16 mono at the configured sample rate.
2. WHEN audio frames arrive THEN the existing YIN detector, note tracker, level and noise meters SHALL behave identically to mobile.
3. WHEN mic permission is denied on Windows THEN the app SHALL surface the existing "denied" state and guidance, not crash.
4. Mic audio SHALL remain in-memory only and never be written to disk, preserving the current privacy guarantee.

## Requirement 7 — Import, PDF, images, and sharing work or degrade honestly on Windows

**User story:** As a Windows user, I want to import MIDI/MusicXML/PDF/image files and view PDFs/scores the same way as on mobile.

#### Acceptance Criteria
1. WHEN the user taps "Import sheet music" on Windows THEN `file_picker` SHALL open the native Windows file dialog and return file bytes/paths that the existing content-sniffing importer accepts (`.mid/.midi/.musicxml/.xml/.mxl/.pdf/.jpg/.png`).
2. WHEN a PDF is imported THEN `pdfrx` SHALL raster pages on Windows for the OMR/review pipeline; IF a required native dependency is missing THEN the design SHALL document the exact setup.
3. WHEN the user picks or captures images: camera capture via `image_picker` MAY be unavailable on Windows; IF so, the UI SHALL hide/disable only the camera affordance and keep file-based image import working, with a clear note.
4. WHEN the user exports a backup via `share_plus` THEN on Windows it SHALL either invoke the platform share or fall back to a "save/reveal file" behavior; the backup zip SHALL always be produced regardless.
5. WHEN permissions are involved (`permission_handler`, only `openAppSettings` is used today) THEN Windows SHALL not crash on the no-op/unsupported calls; the affordance SHALL be hidden or safely no-op where the concept doesn't apply.
6. WHEN `wakelock_plus` is used to keep the screen awake during practice THEN on Windows it SHALL either work or safely no-op without error.
7. Every plugin named here SHALL have its Windows support status explicitly verified and recorded in the design's plugin matrix, with a concrete handling decision (works / shimmed / hidden-with-message).

## Requirement 8 — Platform-aware UI and capability gating

**User story:** As a user on any platform, I want the UI to show only the capabilities that actually work on my platform, with clear messaging where something is unavailable.

#### Acceptance Criteria
1. WHEN the app runs THEN a single capability/platform abstraction SHALL determine which input methods and affordances are shown (e.g., hide BLE scan and camera on Windows), rather than scattering `Platform.isWindows` checks through the UI.
2. WHEN a capability is unavailable on the current platform THEN the UI SHALL present a short, honest explanation instead of a dead button or a crash.
3. Android/iOS SHALL show exactly the same affordances they show today (no regressions).

## Requirement 9 — Tests, analysis, and verification

**User story:** As a maintainer, I want confidence that the Windows port didn't break existing behavior and that Windows paths are covered.

#### Acceptance Criteria
1. WHEN `flutter analyze` is run THEN it SHALL report no new errors introduced by this change (target: clean, matching the project's current state).
2. WHEN `flutter test` is run THEN the existing 115 tests SHALL still pass (no behavioral regressions in `core/`, `data/`, `ui/`).
3. WHERE pure-Dart logic was touched for path handling, THEN unit tests SHALL cover Windows-style path behavior where feasible (host-independent assertions).
4. The design and tasks SHALL include an explicit **manual Windows verification checklist** mirroring the README's MIDI/mic/import manual checks, to be executed on a real Windows machine with a real USB MIDI keyboard.
5. IF Flutter tooling cannot run in this environment THEN every verification step SHALL still be documented with exact commands and expected results, and the limitation SHALL be stated plainly.

## Out of scope
- Any new feature not already present on Android/iOS.
- Linux/macOS/Web targets (Windows only for this spec).
- Rewriting the OMR engine or changing recognition quality.
- BLE MIDI on Windows if the plugin does not support it (explicitly degraded, not implemented).
