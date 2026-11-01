import 'package:flutter_test/flutter_test.dart';
import 'package:stavelight/core/import/import_types.dart';
import 'package:stavelight/ui/import/isolate_jobs.dart';

import '../core/import/omr_test_pages.dart';

/// Runs each background job through a real isolate, as the import UI does. Guards against closures that
/// capture unsendable state (which only fails at runtime, not in analysis).
void main() {
  test('page ops, preview, recognition and PNG encoding run in isolates', () async {
    final page = grandStaffPage().toImage();
    final rotated = await applyPageOp(page, const PageOp(PageOpKind.rotateRight));
    expect(rotated.width, page.height);
    final back = await applyPageOp(rotated, const PageOp(PageOpKind.rotateLeft));
    expect(back.width, page.width);
    final cropped = await applyPageOp(back, const PageOp(PageOpKind.crop, [0, 0, 0.5, 1]));
    expect(cropped.width, closeTo(page.width / 2, 2));
    final preview = await encodePreview(back);
    expect(preview.sublist(0, 2), [0xFF, 0xD8]);
    final result = await recognize([back], const OmrSettings(), 'Synthetic');
    expect(result.anyUsable, isTrue);
    expect(result.score.notes, isNotEmpty);
    final pngs = await encodePagePngs([back]);
    expect(pngs.single.sublist(1, 4), 'PNG'.codeUnits);
    expect(await decodeImageBytes(pngs.single), isNotNull);
  });
}
