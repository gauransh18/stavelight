import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../../core/import/import_types.dart';
import '../../core/import/omr/omr_engine.dart';
import '../../core/import/omr/preprocess.dart';

// Background jobs for import. Each entry point is a synchronous top-level function so the closure handed to
// Isolate.run captures only its plain-data parameters (closures created inside async methods can capture
// the async state machine, which is not sendable).

enum PageOpKind { rotateLeft, rotateRight, crop, perspective, enhance }

/// A page edit described as plain data.
class PageOp {
  final PageOpKind kind;
  final List<double> values; // crop: l,t,r,b — perspective: x0,y0,…,x3,y3 (TL,TR,BR,BL)
  const PageOp(this.kind, [this.values = const []]);
}

img.Image _applyOp(img.Image src, PageOp op) => switch (op.kind) {
      PageOpKind.rotateLeft => rotateQuarter(src, -1),
      PageOpKind.rotateRight => rotateQuarter(src, 1),
      PageOpKind.crop => cropNormalized(src, op.values[0], op.values[1], op.values[2], op.values[3]),
      PageOpKind.perspective => perspectiveCorrect(src, [for (var i = 0; i < 4; i++) (op.values[i * 2], op.values[i * 2 + 1])]),
      PageOpKind.enhance => enhanceForOmr(src, contrast: 1.3),
    };

Future<img.Image> applyPageOp(img.Image src, PageOp op) => Isolate.run(() => _applyOp(src, op));

Uint8List _preview(img.Image src) {
  final small = src.width > 1100 ? img.copyResize(src, width: 1100) : src;
  return Uint8List.fromList(img.encodeJpg(small, quality: 80));
}

Future<Uint8List> encodePreview(img.Image src) => Isolate.run(() => _preview(src));

Future<OmrResult> recognize(List<img.Image> pages, OmrSettings settings, String title) =>
    Isolate.run(() => runOmr(pages, settings, title: title));

img.Image? _decode(Uint8List bytes) {
  final d = img.decodeImage(bytes);
  return d == null ? null : img.bakeOrientation(d);
}

Future<img.Image?> decodeImageBytes(Uint8List bytes) => Isolate.run(() => _decode(bytes));

List<Uint8List> _pngs(List<img.Image> pages) => [
      for (final p in pages) Uint8List.fromList(img.encodePng(p.width > 1600 ? img.copyResize(p, width: 1600) : p)),
    ];

Future<List<Uint8List>> encodePagePngs(List<img.Image> pages) => Isolate.run(() => _pngs(pages));
