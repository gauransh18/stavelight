# Tasks — Windows Support for Stavelight

Each task is incremental, references requirements, and includes a verify step. Check and recheck:
after every code task run `flutter analyze` + `flutter test`; after platform tasks run `flutter build windows`.
If Flutter is unavailable in this environment, record the command and expected output and mark the task
"code-ready, build-unverified here."

## 0. Preconditions & environment
- [ ] 0.1 Confirm Flutter toolchain + Windows desktop support. Run `flutter --version`, `flutter doctor`, `flutter config --enable-windows-desktop`. Requires Visual Studio with "Desktop development with C++". _(Req 1, 9.5)_
  - Expected: doctor shows a ✓ for Visual Studio / Windows toolchain.
- [ ] 0.2 Baseline the untouched repo: `flutter pub get`, `flutter analyze`, `flutter test`. Record the current pass count (expected 115 passing) so regressions are detectable. _(Req 9.1, 9.2)_

## 1. Generate the Windows platform target
- [ ] 1.1 Run `flutter create --platforms=windows .` in the repo root to add `windows/` without touching existing files. Verify `android/` and `ios/` are unchanged (git diff). _(Req 1.1)_
- [ ] 1.2 Set window title "Stavelight" and a default size (1280×800) in `windows/runner/` (main.cpp / Win32Window creation). Set product/app name in `Runner.rc` and `CMakeLists.txt`. _(Req 1.5)_
- [ ] 1.3 `flutter build windows` → produces `build/windows/x64/runner/Release/stavelight.exe` (or Debug). Launch it; confirm onboarding/empty-library renders. _(Req 1.2, 1.3)_
- [ ] 1.4 Recheck mobile unbroken: `flutter build apk --debug` still succeeds (and `flutter build ios --no-codesign` on a Mac if available). _(Req 1.6)_

## 2. Platform capability abstraction
- [ ] 2.1 Add `lib/core/platform/platform_capabilities.dart` with `PlatformCaps` (`isWindows`, `isDesktop`, `bleMidi`, `cameraCapture`, `appSettingsLink`). Pure Dart, only `dart:io`. _(Req 8.1)_
- [ ] 2.2 Unit test the gating logic by passing the booleans into small helper(s)/widgets so behavior is assertable without mutating `Platform`. _(Req 8, 9.3)_

## 3. Filesystem & path correctness
- [ ] 3.1 Add `package:path` (if not transitively present) and route path construction in `lib/data/library_repository.dart` through `p.join(...)` (index/calibration/piece/score/session/pages files, `_writeOriginals`, `_writePages`, `_copyDir`). Keep public behavior identical on mobile. _(Req 2.2)_
- [ ] 3.2 Normalize backup zip entry names to forward slashes regardless of host OS in `exportBackup()`. _(Req 2.5)_
- [ ] 3.3 Verify `JsonStore` atomic temp+rename works on Windows (rename-over-existing semantics); adjust to delete-then-rename or `File.rename` with pre-delete if needed. _(Req 2.1, 2.4)_
- [ ] 3.4 Unit tests (host-independent) for the path-join helper and zip-entry normalization. _(Req 9.3)_
- [ ] 3.5 Manual: on Windows, import a piece, duplicate, replace, delete, export backup; confirm files land under the Windows app-data `stavelight` dir and persist across relaunch. _(Req 2.1, 2.3, 2.4)_

## 4. Audio output Windows sink (core new work)
- [ ] 4.1 Introduce `PcmSink` interface `lib/services/pcm_sink.dart` matching how `AudioOut` uses `flutter_pcm_sound` (`setup`, `setFeedThreshold`, `setFeedCallback`, `feed`, `start`, `release`). _(Req 5.2)_
- [ ] 4.2 Implement `pcm_sink_pcmsound.dart` wrapping current `flutter_pcm_sound` calls verbatim (mobile/macOS path — no behavior change). _(Req 5.4)_
- [ ] 4.3 Implement `pcm_sink_desktop.dart` for Windows. Option 1: add `flutter_soloud` and push `Synth.render()` PCM (Int16 mono 44100) via a raw-PCM stream source on the same ~23 ms cadence. Option 2 fallback: `win32`/WASAPI renderer. _(Req 5.1)_
- [ ] 4.4 Refactor `AudioOut` to select the sink by platform (`PlatformCaps.isWindows`) while keeping its exact public API and `EngineSound` impl. Preserve the init-failure contract (`available=false`, silent, no crash). _(Req 5.2, 5.3)_
- [ ] 4.5 Update `pubspec.yaml` dependencies for the chosen Windows sink; `flutter pub get`. _(Req 5.1)_
- [ ] 4.6 Verify: `flutter analyze` + `flutter test` clean (audio tests use `Synth` directly and must be unaffected). On Windows, hear metronome + count-in + preview + accompaniment. On a mobile device/emulator, confirm audio path unchanged. _(Req 5.1, 5.4, 9.1, 9.2)_

## 5. MIDI over USB on Windows + BLE gating
- [ ] 5.1 In `midi_service.dart`, guard BLE: only `configureBleTransport(UniversalBleMidiTransport())` / `startBluetooth` / scanning when `PlatformCaps.bleMidi`. On Windows, `scanBluetooth()` becomes a safe no-op that sets a clear state/message. Ensure no `StateError` can be thrown by a BLE-only call on Windows. _(Req 4.1, 4.2, 4.4)_
- [ ] 5.2 Keep `refresh()`, `connect()`, setup-change monitoring, `MidiByteParser`, and the `notes`/`pedal` streams unchanged (these cover USB scan, connect, note/pedal, hot-plug, disconnect). _(Req 3.1–3.8)_
- [ ] 5.3 Confirm `MidiService` is owned at app/session level (it is, via `AppState`) so transports aren't recreated per route. _(Req 3.6)_
- [ ] 5.4 Verify `analyze`/`test` clean; mobile MIDI/BLE behavior unchanged. _(Req 4.3, 9)_
- [ ] 5.5 **Manual on Windows with a real USB-B→USB-A MIDI keyboard:**
  - [ ] a. Plug keyboard into PC USB-A; open app; run device scan → keyboard listed. _(Req 3.1)_
  - [ ] b. Select device → status `connected`. _(Req 3.2)_
  - [ ] c. Key test: press keys → correct note numbers/velocities on the `notes` stream/UI. _(Req 3.3)_
  - [ ] d. Sustain pedal (CC64) down/up → pedal events. _(Req 3.4)_
  - [ ] e. Wait-mode practice: cursor stops until the chord is played; Skip appears after timeout. _(parity)_
  - [ ] f. Unplug mid-session → `disconnected`, practice pauses with banner. _(Req 3.5)_
  - [ ] g. Re-plug while app open → reappears without restart. _(Req 3.6)_
  - [ ] h. Calibration: press middle C → transposition detection works; offset applied. _(Req 3.7)_
  - [ ] i. Confirm Bluetooth-scan affordance is hidden/disabled with the "USB only on Windows" note. _(Req 4.2)_

## 6. Microphone on Windows
- [ ] 6.1 Confirm `record` streams PCM16 mono at 22050 Hz on Windows via existing `MicService` (no code change expected). Handle permission-denied → existing `denied` state. _(Req 6.1, 6.3)_
- [ ] 6.2 Manual: calibrate (noise check, C4/C5), practice slowly, confirm wrong-octave reported as octave issue, noisy frames "unclear"; deny permission → explanation. Confirm nothing is written to disk. _(Req 6.2, 6.4)_

## 7. Import / PDF / images / sharing / permissions / wakelock
- [ ] 7.1 `file_picker`: verify native Windows dialog returns bytes/paths the content sniffer accepts (`.mid/.midi/.musicxml/.xml/.mxl/.pdf/.jpg/.png`). _(Req 7.1)_
- [ ] 7.2 `pdfrx`: verify PDF raster works on Windows (PDFium builds in). Import a multi-page PDF → pages raster → OMR/review. _(Req 7.2)_
- [ ] 7.3 `image_picker` camera: gate the "take photo" affordance off on Windows via `PlatformCaps.cameraCapture`; keep file/image import. Confirm no `UnimplementedError` reaches the user. _(Req 7.3)_
- [ ] 7.4 `share_plus` backup export on Windows: verify it shares or implement a save/reveal-file fallback; the backup zip must always be produced. _(Req 7.4)_
- [ ] 7.5 `permission_handler` `openAppSettings`: guard with `PlatformCaps.appSettingsLink` so Windows hides/no-ops it without throwing. _(Req 7.5)_
- [ ] 7.6 `wakelock_plus`: verify enable/disable during practice works or safely no-ops on Windows. _(Req 7.6)_
- [ ] 7.7 Record the final verified Windows status of every plugin in design's matrix (works / shimmed / hidden). _(Req 7.7)_

## 8. UI capability gating pass
- [ ] 8.1 Audit all screens for mobile-only affordances (BLE scan, camera, open-settings) and gate them via `PlatformCaps`. Ensure each hidden/disabled control has a short honest message. _(Req 8.1, 8.2)_
- [ ] 8.2 Diff mobile UI before/after to confirm zero change on Android/iOS. _(Req 8.3)_

## 9. Full verification & recheck
- [ ] 9.1 `flutter analyze` → clean (no new errors). _(Req 9.1)_
- [ ] 9.2 `flutter test` → 115 (baseline) still passing + any new unit tests green. _(Req 9.2, 9.3)_
- [ ] 9.3 `flutter build windows` → succeeds; launch and smoke-test end-to-end. _(Req 1.2)_
- [ ] 9.4 `flutter build apk --debug` → still succeeds (mobile not broken). _(Req 1.6)_
- [ ] 9.5 Execute the full manual Windows checklist (sections 5.5, 6.2, 7) on real hardware; record results. _(Req 9.4)_
- [ ] 9.6 Update `README.md`/`docs/ARCHITECTURE.md` "Platform notes" and verification status to include Windows (USB MIDI supported, BLE not, camera not, audio via desktop sink). _(docs parity)_
- [ ] 9.7 Final recheck: re-read requirements.md acceptance criteria one by one against the running build; note any criterion that could not be verified in-environment and why. _(Req 9.5)_

## Notes on verification honesty
- Items requiring a real Windows machine, a real USB MIDI keyboard, a microphone, or the Flutter desktop toolchain cannot be fully verified in the current agent environment (Flutter is not on PATH here). Those are marked for manual execution with exact commands and expected outcomes. Code will be delivered build-ready.
