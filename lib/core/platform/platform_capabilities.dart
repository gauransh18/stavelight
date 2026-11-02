import 'dart:io' show Platform;

/// Centralizes platform/capability decisions so `Platform.isWindows` checks do
/// not leak across the UI and services. Mobile (Android/iOS) returns the same
/// values it always had, so mobile behavior is unchanged.
///
/// Rationale: Windows (and desktop generally) lacks some capabilities that the
/// current plugins only implement on mobile:
///   - BLE MIDI transport (flutter_midi_command has no Windows BLE backend)
///   - Camera capture via image_picker (Windows is gallery-only; camera throws
///     UnimplementedError)
///   - "Open app settings" deep link (a mobile concept)
///
/// Where a capability is false, the UI hides/disables only that affordance and
/// shows an honest message instead of crashing.
class PlatformCaps {
  const PlatformCaps._();

  static bool get isWindows => Platform.isWindows;
  static bool get isLinux => Platform.isLinux;
  static bool get isMacOS => Platform.isMacOS;
  static bool get isDesktop => Platform.isWindows || Platform.isLinux || Platform.isMacOS;
  static bool get isMobile => Platform.isAndroid || Platform.isIOS;

  /// Bluetooth LE MIDI available? The bundled plugin supports BLE MIDI on
  /// Android/iOS/macOS but not on Windows.
  static bool get bleMidi => !Platform.isWindows;

  /// Live camera capture available through image_picker? Not on desktop.
  static bool get cameraCapture => isMobile;

  /// Is picking photos from a gallery/library meaningful? Mobile only; on
  /// desktop users choose image files through the file picker instead.
  static bool get photoLibrary => isMobile;

  /// Does an "Open app settings" deep link make sense on this platform?
  static bool get appSettingsLink => isMobile;

  /// Prefer sharing via the OS share sheet (mobile) vs. saving/revealing a
  /// file (desktop has no universal share sheet across all shells).
  static bool get hasShareSheet => isMobile || Platform.isMacOS;

  /// Short human-readable platform label used in a few messages.
  static String get label {
    if (Platform.isWindows) return 'Windows';
    if (Platform.isMacOS) return 'macOS';
    if (Platform.isLinux) return 'Linux';
    if (Platform.isAndroid) return 'Android';
    if (Platform.isIOS) return 'iOS';
    return 'this platform';
  }
}
