# Stavelight — Windows Build & Verification Checklist

This checklist takes the `windows-support` branch from source to a verified Windows build.
Run it on a **Windows 10/11 PC** with a real USB MIDI keyboard. Every code change is already
committed on the branch; what remains is generating the native `windows/` runner, installing
dependencies, building, and verifying on hardware.

> Why these steps exist: the port was implemented in an environment without the Flutter
> toolchain, so nothing here could be compiled or run yet. Treat every box as unverified until
> you check it. Where something fails, the "If it fails" notes point at the most likely cause.

---

## 0. Install the toolchain (one time)

- [ ] Install **Flutter** (3.11+/Dart 3.11 to match `pubspec.yaml`), add it to PATH.
- [ ] Install **Visual Studio 2022** with the **"Desktop development with C++"** workload
      (required for Flutter Windows builds — not just VS Code).
- [ ] `flutter config --enable-windows-desktop`
- [ ] `flutter doctor -v` → confirm **Visual Studio** and **Windows** show ✓.

## 1. Get the branch and baseline it

- [ ] `git checkout windows-support`
- [ ] `flutter pub get`
      - If it fails resolving `flutter_soloud`: see note in step 4 (native-assets / version).
- [ ] `flutter analyze`  → record the result. Target: **no errors**.
- [ ] `flutter test`     → record the pass count. Target: **all existing tests + the new
      backup-slash test pass** (baseline was 115; expect 116 with the added test).

## 2. Generate the Windows runner (native folder)

The `windows/` folder is intentionally **not** committed — it is generated per Flutter version.

- [ ] From the repo root run: `flutter create --platforms=windows .`
      - This adds `windows/` only; it must **not** modify `lib/`, `android/`, or `ios/`.
- [ ] `git status` → confirm only `windows/` (and maybe `.metadata`) is new/changed.

### 2a. Set the window title and size (small manual edit)

In `windows/runner/main.cpp`, find the `window.Create(...)` / `CreateAndShow` call. Set:
- [ ] Title string to **`Stavelight`**
- [ ] Default size to roughly **1280 x 800** (the `size` / `Win32Window::Size` argument).

(These are the only app-specific native edits. The rest of the runner is standard.)

## 3. First Windows build & launch

- [ ] `flutter build windows`  → produces `build\windows\x64\runner\Release\stavelight.exe`.
- [ ] `flutter run -d windows` (debug) → app launches.
- [ ] Onboarding / empty library screen renders.         _(Req 1.3)_
- [ ] Window title bar reads "Stavelight".                _(Req 1.5)_

## 4. Dependency sanity (audio is the risk area)

- [ ] `flutter_soloud` resolved and built. It is the Windows audio backend replacing
      `flutter_pcm_sound` (which has no Windows support).
      - **If `flutter pub get` or build fails on `flutter_soloud`:**
        1. Check the version. `pubspec.yaml` pins `^5.2.2`. If your Flutter is older than what
           v5 needs (it uses native-assets / `hooks`), either upgrade Flutter, or pin an older
           soloud (e.g. `^2.x`) and adjust `lib/services/pcm_sink_desktop.dart` to that version's
           stream API (`setBufferStream`/`addAudioDataStream` names are stable across recent 2.x/5.x).
        2. Re-run `flutter pub get`.
- [ ] `flutter_pcm_sound` not registering on Windows is EXPECTED and harmless — it is only used
      on Android/iOS/macOS and is never invoked on Windows.

## 5. USB MIDI keyboard — scan, connect, read (core requirement)

Connect your MIDI keyboard to the PC with the **USB-B (keyboard) → USB-A (PC)** cable.
A class-compliant keyboard needs **no driver** — Windows enumerates it as a MIDI input.

- [ ] Open the app's MIDI/calibration screen and tap **Refresh**. The keyboard appears in the
      device list.                                                          _(Req 3.1)_
- [ ] Select it → status becomes **connected**.                             _(Req 3.2)_
- [ ] Press keys → correct note names/numbers and velocities register.      _(Req 3.3)_
- [ ] Press/release the **sustain pedal** → pedal (CC64) down/up registers.  _(Req 3.4)_
- [ ] Start a piece in **Wait mode**: the cursor stops until you play the expected chord; a
      **Skip** option appears after the timeout.                            _(parity)_
- [ ] **Unplug** the cable mid-session → status goes **disconnected** and practice pauses with a
      banner.                                                               _(Req 3.5)_
- [ ] **Re-plug** while the app is still open → the keyboard reappears in the list without
      restarting the app.                                                   _(Req 3.6)_
- [ ] Open calibration, press **middle C** → transposition detection works; the offset is applied
      to subsequent notes.                                                  _(Req 3.7)_
- [ ] Confirm the **"Scan for Bluetooth MIDI"** button is **absent** and a note says USB is the
      Windows path.                                                         _(Req 4.2)_
- [ ] Nothing throws when BLE is unavailable (no red error screens).        _(Req 4.4)_

  If the keyboard does NOT appear:
  - Confirm it shows in Windows **Device Manager → Sound, video and game controllers** or as a
    MIDI device. If Windows itself doesn't see it, it's a cable/driver issue, not the app.
  - Try a different USB-A port; avoid unpowered hubs.

## 6. Audio output (metronome / preview / count-in / accompaniment)

- [ ] Enable the **metronome** in practice → you hear clicks.               _(Req 5.1)_
- [ ] **Count-in** before practice is audible.
- [ ] **Preview playback** of a piece plays notes.
- [ ] **"Play the other hand for me"** accompaniment is audible.
- [ ] If audio is silent but the app is otherwise fine: that is the designed **honest-failure**
      path (`AudioOut.available == false`). Check the debug console for "Audio output unavailable".
      Most likely cause: `flutter_soloud` init failing — see step 4.        _(Req 5.3)_
- [ ] Audio has no obvious stutter/underrun at normal tempo. (The desktop sink feeds ~every 10 ms;
      if you hear dropouts, note it — the lead-buffer timing in `pcm_sink_desktop.dart` can be
      widened via `bufferingTimeNeeds`.)                                     _(Req 5.5)_

## 7. Microphone input

- [ ] Choose **mic input**; Windows prompts for / already allows microphone access.  _(Req 6.1)_
- [ ] Run **calibration**: noise check, play C4 then C5 — detection works.  _(Req 6.2)_
- [ ] Practise slowly: wrong-octave is reported as an octave issue; noisy frames as "unclear".
- [ ] **Deny** microphone permission in Windows settings → the app shows the "denied" explanation
      instead of crashing.                                                  _(Req 6.3)_

## 8. Import / PDF / images / backup

- [ ] **Import → Choose a file**: the native Windows file dialog opens; import a **.mid**, a
      **.musicxml**, and a **.mxl** — all accepted (content-sniffed).        _(Req 7.1)_
- [ ] Import a multi-page **PDF** → pages rasterize → recognition/review runs.  _(Req 7.2)_
- [ ] Import an image file (**.jpg/.png**) via "Choose a file".
- [ ] Confirm the **"Photograph pages"** (camera) option is **absent** on Windows, and there is no
      crash related to camera.                                              _(Req 7.3)_
- [ ] **Export backup** (Settings): a `.zip` is written and a snackbar shows the exact path under
      `Documents\...\stavelight\Stavelight backups\`. Open the zip and confirm its entries use
      forward slashes and the files are present.                            _(Req 7.4, 2.5)_
- [ ] **Keep-awake** during practice works or silently no-ops (screen shouldn't error).  _(Req 7.6)_

## 9. Persistence & paths

- [ ] Import a few pieces, **duplicate** one, **replace** one, **delete** one — all succeed.  _(Req 2.3)_
- [ ] Fully **close and relaunch** the app → library, scores, sessions, calibration and settings
      all persist.                                                          _(Req 2.4)_
- [ ] Data lives under the Windows app-documents dir (e.g.
      `C:\Users\<you>\Documents\stavelight\` or the path `path_provider` returns).  _(Req 2.1)_

## 10. Mobile not broken (regression)

- [ ] `flutter build apk --debug` still succeeds.                           _(Req 1.6)_
- [ ] (If you have a Mac) `flutter build ios --no-codesign` still succeeds.
- [ ] On an Android device/emulator, MIDI (incl. BLE if you use it), audio, camera, and photos
      still behave exactly as before — the Windows gating must not have hidden anything on mobile. _(Req 8.3)_

## 11. Final sign-off

- [ ] `flutter analyze` clean.
- [ ] `flutter test` green.
- [ ] All of sections 5–9 pass on real hardware.
- [ ] Note any criterion you could **not** verify and why.

---

## What changed on this branch (for your review)

Code (all under `lib/`):
- `core/platform/platform_capabilities.dart` — **new.** Central `PlatformCaps` (isWindows, bleMidi,
  cameraCapture, photoLibrary, appSettingsLink, isDesktop, label). Mobile values unchanged.
- `services/pcm_sink.dart` — **new.** `PcmSink` interface (the only platform-specific audio seam).
- `services/pcm_sink_pcmsound.dart` — **new.** Wraps `flutter_pcm_sound` verbatim (mobile/macOS).
- `services/pcm_sink_desktop.dart` — **new.** Windows/Linux sink via `flutter_soloud` raw-PCM stream.
- `services/audio_out.dart` — now selects the sink by platform; **public API and the Synth/engine
  are unchanged**, so mobile audio is byte-identical.
- `services/midi_service.dart` — BLE is gated behind `bleSupported`; on Windows `scanBluetooth()` is
  a safe no-op with a clear message. USB scan/connect/note/pedal/hot-plug/disconnect are untouched
  (the plugin already supports Windows USB MIDI).
- `data/library_repository.dart` — all path building now uses `package:path` (OS-correct); backup
  zip entries normalized to forward slashes.
- `data/json_store.dart` — atomic write now falls back to delete-then-rename (Win32 can't rename
  over an existing file).
- `ui/calibration/calibration_screen.dart` — hides the Bluetooth-scan button on Windows + note.
- `ui/import/import_flow.dart` — hides camera/photos on desktop; guards `openAppSettings`.
- `ui/settings/settings_screen.dart` — backup export saves to a file + path on desktop (no share
  sheet), still shares on mobile.

Dependencies (`pubspec.yaml`):
- Added `flutter_soloud: ^5.2.2` (Windows/Linux audio) and `path: ^1.9.0` (explicit, was transitive).

Spec (for the full rationale): `.kiro/specs/windows-support/{requirements,design,tasks}.md`.

## Known honest limitations on Windows
- **Bluetooth MIDI: not available** (plugin has no Windows BLE backend). USB is the supported path.
- **Camera capture: not available** (`image_picker` is gallery-only on Windows). Use file import.
- **Audio** uses a different backend (`flutter_soloud`) than mobile; it is functionally equivalent
  but its exact latency on your hardware is unverified — check section 6.
- Everything else is intended to match mobile behavior exactly.
