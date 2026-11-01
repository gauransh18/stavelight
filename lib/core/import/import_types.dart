import 'dart:typed_data';

import '../model/pitch.dart';
import '../model/score.dart';

enum ImportFormat { midi, musicxml, mxl, pdf, image, unknown }

/// Thrown when a file cannot be imported. [message] is user-facing; [detail] is for diagnostics.
class ImportException implements Exception {
  final String message;
  final String? detail;
  ImportException(this.message, [this.detail]);
  @override
  String toString() => 'ImportException: $message${detail != null ? ' ($detail)' : ''}';
}

/// Identify a file by content (magic bytes), falling back to the file name.
ImportFormat sniffFormat(Uint8List bytes, {String? fileName}) {
  bool starts(List<int> sig, [int offset = 0]) {
    if (bytes.length < offset + sig.length) return false;
    for (var i = 0; i < sig.length; i++) {
      if (bytes[offset + i] != sig[i]) return false;
    }
    return true;
  }

  if (starts([0x4D, 0x54, 0x68, 0x64])) return ImportFormat.midi; // MThd
  if (starts([0x52, 0x49, 0x46, 0x46]) && starts([0x52, 0x4D, 0x49, 0x44], 8)) return ImportFormat.midi; // RIFF RMID
  if (starts([0x25, 0x50, 0x44, 0x46])) return ImportFormat.pdf; // %PDF
  if (starts([0x89, 0x50, 0x4E, 0x47])) return ImportFormat.image; // PNG
  if (starts([0xFF, 0xD8, 0xFF])) return ImportFormat.image; // JPEG
  if (starts([0x47, 0x49, 0x46, 0x38])) return ImportFormat.image; // GIF
  if (starts([0x42, 0x4D])) return ImportFormat.image; // BMP
  if (starts([0x52, 0x49, 0x46, 0x46]) && starts([0x57, 0x45, 0x42, 0x50], 8)) return ImportFormat.image; // WEBP
  if (starts([0x49, 0x49, 0x2A, 0x00]) || starts([0x4D, 0x4D, 0x00, 0x2A])) return ImportFormat.image; // TIFF
  if (starts([0x50, 0x4B, 0x03, 0x04])) return ImportFormat.mxl; // ZIP (compressed MusicXML)

  final head = String.fromCharCodes(bytes.take(4096).where((b) => b < 128));
  if (head.contains('<score-partwise') || head.contains('<score-timewise') || head.contains('MusicXML')) {
    return ImportFormat.musicxml;
  }

  final ext = (fileName ?? '').toLowerCase().split('.').last;
  switch (ext) {
    case 'mid':
    case 'midi':
      return ImportFormat.midi;
    case 'musicxml':
    case 'xml':
      return ImportFormat.musicxml;
    case 'mxl':
      return ImportFormat.mxl;
    case 'pdf':
      return ImportFormat.pdf;
    case 'jpg':
    case 'jpeg':
    case 'png':
    case 'heic':
    case 'webp':
      return ImportFormat.image;
  }
  return ImportFormat.unknown;
}

/// Settings the user confirms before OMR runs. Clef/key/time are not guessed silently.
class OmrSettings {
  /// True for piano grand staff (staves paired upper/lower). False = each staff independent.
  final bool grandStaff;
  final ClefKind upperClef;
  final ClefKind lowerClef;

  /// Clef used for every staff when [grandStaff] is false.
  final ClefKind singleClef;
  final KeySignature key;
  final TimeSignature time;
  final double bpm;

  const OmrSettings({
    this.grandStaff = true,
    this.upperClef = ClefKind.treble,
    this.lowerClef = ClefKind.bass,
    this.singleClef = ClefKind.treble,
    this.key = const KeySignature(0),
    this.time = const TimeSignature(4, 4),
    this.bpm = 90,
  });

  OmrSettings copyWith({
    bool? grandStaff,
    ClefKind? upperClef,
    ClefKind? lowerClef,
    ClefKind? singleClef,
    KeySignature? key,
    TimeSignature? time,
    double? bpm,
  }) =>
      OmrSettings(
        grandStaff: grandStaff ?? this.grandStaff,
        upperClef: upperClef ?? this.upperClef,
        lowerClef: lowerClef ?? this.lowerClef,
        singleClef: singleClef ?? this.singleClef,
        key: key ?? this.key,
        time: time ?? this.time,
        bpm: bpm ?? this.bpm,
      );
}

/// Per-page OMR outcome. When [ok] is false, [failureReason] says what to fix.
class OmrPageReport {
  final int pageIndex;
  final bool ok;
  final String? failureReason;
  final List<String> hints;
  final int stavesFound;
  final double staffSpacingPx;
  final int notesFound;
  final double meanConfidence;

  OmrPageReport({
    required this.pageIndex,
    required this.ok,
    this.failureReason,
    this.hints = const [],
    this.stavesFound = 0,
    this.staffSpacingPx = 0,
    this.notesFound = 0,
    this.meanConfidence = 0,
  });
}

class OmrResult {
  final Score score;
  final List<OmrPageReport> pages;
  OmrResult(this.score, this.pages);
  bool get anyUsable => pages.any((p) => p.ok);
}
