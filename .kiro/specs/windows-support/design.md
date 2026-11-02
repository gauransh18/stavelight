# Design — Windows Support for Stavelight

## Overview

This is a compatibility port, not a feature change. We add a native Windows desktop target and make every existing capability either work on Windows or degrade honestly (visible message + disabled affordance, never a crash). Android/iOS code paths and behavior are left untouched.

The work breaks into five problem areas:
1. **Platform scaffolding** — generate `windows/`, enable desktop, set window title/size.
2. **Audio output** — `flutter_pcm_sound` has no Windows backend; this is the only hard blocker and needs a Windows PCM sink behind the existing interface.
3. **MIDI over USB** — `flutter_midi_command 1.x` already supports Windows USB MIDI; main work is BLE gating and verification.
4. **Filesystem/paths** — make path building OS-correct; `path_provider` already resolves a Windows app-data dir.
5. **Capability gating & plugin degradation** — one platform/capability abstraction, consumed by the UI.

## Plugin Windows-support matrix (verified during spec; re-verify exact versions at execution)

| Plugin (pubspec) | Windows? | Decision |
|---|---|---|
| `flutter_midi_command ^1.0.3` | USB: **yes** (win32/WinMM, USB hot-plug monitoring). BLE: **no** on Windows. | Keep for USB. Gate BLE off on Windows. |
| `flutter_midi_command_ble ^1.4.0` | Not used as a Windows transport | Only configure BLE transport on non-Windows. |
| `flutter_pcm_sound ^3.3.3` | **No** (Flutter/Android/iOS/macOS only) | **Blocker.** Add Windows PCM sink behind `AudioOut`/`EngineSound`. |
| `record ^6.2.1` | **Yes** | Use as-is for mic. |
| `pdfrx ^2.4.7` | **Yes** (PDFium: Android/iOS/Windows/macOS/Linux/Web) | Use as-is; confirm native build pulls PDFium on Windows. |
| `file_picker ^13.3.0` | **Yes** (desktop) | Use as-is. |
| `path_provider ^2.1.6` | **Yes** (first-party) | Use as-is; returns `%APPDATA%\<app>` style dir. |
| `shared_preferences ^2.5.6` | **Yes** (first-party) | Use as-is. |
| `permission_handler ^12.0.1` | Partial on Windows; app only calls `openAppSettings` | Guard/no-op on Windows; verify no throw. |
| `image_picker ^1.2.4` | Gallery **yes**, **camera no** (`UnimplementedError`) on Windows | Gate camera affordance off on Windows; keep file/gallery import. |
| `wakelock_plus ^1.7.0` | **Yes** | Use as-is. |
| `share_plus ^13.3.1` | **Yes** (Windows) | Use as-is; confirm share/reveal behavior; fall back to save-to-path if needed. |
| `image ^4.12.0`, `archive`, `xml`, `uuid`, `provider`, `pdfrx`'s deps | Pure Dart / cross-platform | No change. |

> The two items that most need a live double-check on Windows are `share_plus` (share vs. save UX) and `permission_handler` (`openAppSettings` behavior). Both are non-blocking: worst case they are hidden/no-op'd. The `flutter_pcm_sound` gap is the only one requiring new code.

## Architecture changes

### A. Platform / capability abstraction (new)

New file `lib/core/platform/platform_capabilities.dart` — a tiny, dependency-free module that centralizes platform checks so `Platform.isWindows` does not leak across the UI (Requirement 8).

```dart
// Pure Dart; import 'dart:io' only.
import 'dart:io' show Platform;

class PlatformCaps {
  static bool get isWindows => Platform.isWindows;
  static bool get isDesktop => Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  /// BLE MIDI transport available on this platform?
  static bool get bleMidi => !Platform.isWindows; // plugin has no Windows BLE
  /// Camera capture available (image_picker camera source)?
  static bool get cameraCapture => !isDesktop; // image_picker camera unsupported on desktop
  /// App-settings deep link meaningful here?
  static bool get appSettingsLink => Platform.isAndroid || Platform.isIOS;
}
```

The value of `bleMidi`/`cameraCapture` for mobile stays `true`, preserving mobile UI exactly. Tests can't flip `Platform` easily, so the consuming widgets receive the booleans (not call statics directly) to keep them unit-testable where practical.

### B. Audio output — Windows PCM sink (the core new work)

`AudioOut` currently implements `EngineSound` and feeds a Dart `Synth` to `flutter_pcm_sound`. `PracticeEngine` and `Synth` must not change (Requirement 5.2/5.4). We introduce a sink seam.

Design choice: keep `flutter_pcm_sound` for Android/iOS (unchanged), add a Windows implementation selected at runtime. Two viable options for the Windows sink:

- **Option 1 (preferred): add a cross-platform PCM dependency that supports Windows** and route `AudioOut`'s feed callback into it on Windows. Candidate: `flutter_soloud` (Windows/Linux/macOS/Android/iOS, FFI, supports pushing raw PCM buffers via an audio stream source). The Dart `Synth.render()` output (Int16 PCM, mono, 44100) is converted to the sink's expected format and pushed on the same ~23 ms cadence.
- **Option 2 (fallback): a minimal Windows WASAPI/`win32` PCM renderer** behind the same interface if a suitable pub package proves unsuitable. Higher effort; only if Option 1 fails.

Structure:
```
lib/services/audio_out.dart            // AudioOut: picks backend by platform, same public API + EngineSound impl
lib/services/pcm_sink.dart             // abstract PcmSink { setup(); setFeedCallback(); feed(); start(); release(); }
lib/services/pcm_sink_pcmsound.dart    // wraps flutter_pcm_sound (mobile/macos) — current behavior
lib/services/pcm_sink_desktop.dart     // Windows sink (Option 1: flutter_soloud)
```

`AudioOut` keeps its exact external contract: `available`, `init()`, `setVolumes()`, `click/noteOn/noteOff/allOff`, `dispose()`, and the `_onFeed`/feed-threshold cadence. Only the sink behind it changes per platform. On init failure on Windows it sets `_failed=true` and the app runs silently — identical to today's failure contract (Requirement 5.3).

> Rationale: the whole audio model (synth, mixer, feed loop) already lives in Dart and is platform-agnostic. The only platform-specific thing is "hand these PCM bytes to the OS." Isolating that to a `PcmSink` keeps `Synth`/`PracticeEngine`/tests unchanged and keeps mobile byte-for-byte identical.

### C. MIDI service — BLE gating only

`lib/services/midi_service.dart` logic is largely reusable because `flutter_midi_command` handles Windows USB natively. Changes:
- In `scanBluetooth()` and the BLE transport configuration, guard with `PlatformCaps.bleMidi`. On Windows, do not call `configureBleTransport`, `startBluetooth`, or scanning; instead set a benign state so the UI can show "BLE MIDI not available on Windows."
- Keep `refresh()`, `connect()`, `_onSetupChanged()`, `_markDisconnected()`, the `MidiByteParser`, and both streams unchanged — these drive USB scan, connect, note/pedal read, hot-plug, and disconnect (Requirements 3.1–3.8).
- Optionally adopt the plugin's typed parser, but to minimize risk we keep the existing hand-written `MidiByteParser` (already handles running status and CC64) — no behavioral change across platforms.

USB-B→USB-A specifics: a class-compliant USB MIDI keyboard enumerates through the Windows USB-audio driver and appears as a WinMM MIDI input. No app-side USB/driver code is needed; the device shows up in `_midi.devices`. The design explicitly relies on the plugin's documented Windows "USB MIDI hot-plug" and "multi-port WinMM endpoints paired into full-duplex devices" behavior.

### D. Filesystem & paths

- `lib/main.dart` uses `getApplicationDocumentsDirectory()` → on Windows this resolves to the user's Documents/AppData-style directory; append `stavelight`. Keep as-is; verify the resolved path is writable.
- `lib/data/library_repository.dart` builds paths with string interpolation using `/`. On Windows, Dart's `dart:io` accepts `/` in most APIs, but to be correct and robust we will route path joins through `package:path` (`p.join`) or `Platform.pathSeparator`. The existing `_copyDir` already splits on `Platform.pathSeparator`; we make construction consistent. Backup zip relative paths are normalized to `/` (zip standard) regardless of OS (Requirement 2.5).
- No change to `JsonStore` atomic temp+rename semantics (works on Windows; note Windows rename-over-existing requires the temp+rename to target a non-open file — verify `JsonStore` deletes/replaces correctly on Windows).

### E. UI capability gating

- Input/connection screens read `PlatformCaps.bleMidi` to hide/disable the Bluetooth-scan button on Windows with a one-line explanation.
- Import/camera screens read `PlatformCaps.cameraCapture` to hide the "take photo" affordance on Windows while keeping "pick file/image."
- Any "Open app settings" link reads `PlatformCaps.appSettingsLink`.
- Mobile returns `true` for all of these, so mobile UI is unchanged (Requirement 8.3).

## Windows runner configuration
- `flutter create --platforms=windows .` generates `windows/runner/`. Set:
  - Window title "Stavelight" and a default size (e.g. 1280×800) in `windows/runner/main.cpp`/`flutter_window` setup.
  - App/product name and metadata in `windows/runner/Runner.rc` and `CMakeLists.txt`.
- Microphone capability: Windows desktop apps generally do not need a manifest capability for mic when running unpackaged; if packaged (MSIX) later, document the `microphone` capability. For now, rely on `record`'s handling and OS prompt.

## Error handling & honest degradation (cross-cutting)
- Audio init failure → `available=false`, silent run (existing contract).
- BLE on Windows → never called; UI shows "USB only on Windows."
- Camera on Windows → affordance hidden; file import still works.
- MIDI unavailable → `MidiStatus.unavailable` + message (existing).
- `permission_handler`/`share_plus` unsupported edge on Windows → wrapped in try/catch with a user-visible, non-fatal message.

## Testing strategy
- **Unit (host-independent):** path-join helper correctness; backup zip entries always use `/`; capability booleans produce expected UI gating given injected flags.
- **Regression:** run existing `flutter test` (115 tests) unchanged; nothing in `core/`, `data/`, `ui/` logic should change behavior.
- **Static:** `flutter analyze` clean.
- **Manual on real Windows + USB keyboard** (mirrors README manual checks): see tasks.md checklist — scan, connect, key test, sustain, Wait-mode cursor gating, unplug banner, hot-plug re-list, calibration middle-C, metronome/preview audio, mic calibration, PDF/MIDI/MusicXML import, backup export.

## Environment risk
Flutter is **not on PATH** in the current agent environment. All `flutter ...` steps are documented with exact commands and expected outputs so a maintainer can execute on a Windows machine with the Flutter Windows toolchain (Visual Studio C++ desktop workload). Code will be written build-ready; where a dependency must be added (audio sink), `pubspec.yaml` changes and integration are specified precisely.

## Decisions log
- Keep the hand-written `MidiByteParser` rather than swapping to the plugin's parser → smaller blast radius, identical cross-platform behavior.
- Isolate the only true blocker (`flutter_pcm_sound` on Windows) behind a `PcmSink` seam instead of replacing the plugin everywhere → mobile stays byte-identical.
- Centralize platform checks in `PlatformCaps` → satisfies Requirement 8, keeps UI testable, avoids scattered `Platform.isWindows`.
- Degrade (not implement) BLE MIDI and camera on Windows → matches "same functionality where possible, honest where not."
