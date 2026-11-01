import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:pdfrx/pdfrx.dart';

import '../core/import/import_types.dart';

/// Renders PDF pages on-device (PDFium) for OMR. Nothing leaves the device.
class PdfRaster {
  static Future<List<img.Image>> render(Uint8List pdf, {double targetLongSide = 2400, int maxPages = 40}) async {
    await pdfrxFlutterInitialize();
    PdfDocument doc;
    try {
      doc = await PdfDocument.openData(pdf);
    } catch (e) {
      throw ImportException('This PDF could not be opened. It may be damaged or password-protected.', '$e');
    }
    try {
      final out = <img.Image>[];
      for (final page in doc.pages.take(maxPages)) {
        final scale = targetLongSide / (page.width > page.height ? page.width : page.height);
        final w = (page.width * scale).round(), h = (page.height * scale).round();
        final rendered = await page.render(fullWidth: w.toDouble(), fullHeight: h.toDouble(), width: w, height: h, backgroundColor: 0xFFFFFFFF);
        if (rendered == null) continue;
        out.add(img.Image.fromBytes(
          width: rendered.width,
          height: rendered.height,
          bytes: rendered.pixels.buffer,
          numChannels: 4,
          order: img.ChannelOrder.bgra,
        ).clone());
        rendered.dispose();
      }
      if (out.isEmpty) throw ImportException('No pages could be rendered from this PDF.');
      return out;
    } finally {
      await doc.dispose();
    }
  }
}
