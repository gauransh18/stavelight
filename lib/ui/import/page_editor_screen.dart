import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import 'isolate_jobs.dart';

enum _Tool { none, crop, perspective }

class _Page {
  final img.Image original;
  img.Image current;
  Uint8List? preview;
  _Page(this.original) : current = original;
}

/// Order, rotate, crop, straighten and enhance pages before recognition. Returns the processed pages.
class PageEditorScreen extends StatefulWidget {
  final List<img.Image> pages;
  const PageEditorScreen({super.key, required this.pages});
  @override
  State<PageEditorScreen> createState() => _PageEditorScreenState();
}

class _PageEditorScreenState extends State<PageEditorScreen> {
  late final List<_Page> _pages = [for (final p in widget.pages) _Page(p)];
  int _sel = 0;
  _Tool _tool = _Tool.none;
  bool _busy = false;
  // Normalized corners TL, TR, BR, BL.
  List<Offset> _corners = const [Offset(0.03, 0.03), Offset(0.97, 0.03), Offset(0.97, 0.97), Offset(0.03, 0.97)];

  @override
  void initState() {
    super.initState();
    for (final p in _pages) {
      _renderPreview(p);
    }
  }

  Future<void> _renderPreview(_Page p) async {
    final src = p.current;
    final bytes = await encodePreview(src);
    if (mounted) setState(() => p.preview = bytes);
  }

  Future<void> _apply(PageOp op) async {
    final page = _pages[_sel];
    setState(() => _busy = true);
    final src = page.current;
    try {
      final out = await applyPageOp(src, op);
      page.current = out;
      await _renderPreview(page);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _resetCorners() =>
      _corners = const [Offset(0.03, 0.03), Offset(0.97, 0.03), Offset(0.97, 0.97), Offset(0.03, 0.97)];

  @override
  Widget build(BuildContext context) {
    final page = _pages.isEmpty ? null : _pages[_sel.clamp(0, _pages.length - 1)];
    return Scaffold(
      appBar: AppBar(
        title: Text(_pages.length > 1 ? 'Pages (${_sel + 1} of ${_pages.length})' : 'Prepare page'),
        actions: [
          TextButton(
            onPressed: _busy || _pages.isEmpty ? null : () => Navigator.pop(context, [for (final p in _pages) p.current]),
            child: const Text('Next'),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(children: [
          if (_tool == _Tool.none)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                'For best recognition: page upright, straight edges, staves clearly visible. Crop away the background.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          Expanded(
            child: page?.preview == null
                ? const Center(child: CircularProgressIndicator())
                : Padding(
                    padding: const EdgeInsets.all(12),
                    child: Center(child: _PageCanvas(
                      image: page!.preview!,
                      aspect: page.current.width / page.current.height,
                      tool: _tool,
                      corners: _corners,
                      onCorners: (c) => setState(() => _corners = c),
                    )),
                  ),
          ),
          if (_busy) const LinearProgressIndicator(),
          _toolbar(page),
          if (_pages.length > 1 || _tool == _Tool.none) _strip(),
        ]),
      ),
    );
  }

  Widget _toolbar(_Page? page) {
    if (page == null) return const SizedBox.shrink();
    if (_tool != _Tool.none) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          Expanded(
            child: Text(_tool == _Tool.crop ? 'Drag the corners to crop.' : 'Drag each corner onto a corner of the page.'),
          ),
          TextButton(onPressed: () => setState(() => _tool = _Tool.none), child: const Text('Cancel')),
          FilledButton(
            onPressed: _busy
                ? null
                : () async {
                    final c = _corners;
                    final tool = _tool;
                    setState(() => _tool = _Tool.none);
                    if (tool == _Tool.crop) {
                      final l = c.map((o) => o.dx).reduce((a, b) => a < b ? a : b);
                      final r = c.map((o) => o.dx).reduce((a, b) => a > b ? a : b);
                      final t = c.map((o) => o.dy).reduce((a, b) => a < b ? a : b);
                      final b = c.map((o) => o.dy).reduce((a, b) => a > b ? a : b);
                      await _apply(PageOp(PageOpKind.crop, [l, t, r, b]));
                    } else {
                      await _apply(PageOp(PageOpKind.perspective, [for (final o in c) ...[o.dx, o.dy]]));
                    }
                  },
            child: const Text('Apply'),
          ),
        ]),
      );
    }
    Widget tool(IconData i, String label, VoidCallback? onTap) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            IconButton.filledTonal(tooltip: label, onPressed: _busy ? null : onTap, icon: Icon(i)),
            Text(label, style: Theme.of(context).textTheme.labelSmall),
          ]),
        );
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Row(children: [
        tool(Icons.rotate_left, 'Rotate left', () => _apply(const PageOp(PageOpKind.rotateLeft))),
        tool(Icons.rotate_right, 'Rotate right', () => _apply(const PageOp(PageOpKind.rotateRight))),
        tool(Icons.crop, 'Crop', () => setState(() {
              _resetCorners();
              _tool = _Tool.crop;
            })),
        tool(Icons.perm_media_outlined, 'Straighten', () => setState(() {
              _resetCorners();
              _tool = _Tool.perspective;
            })),
        tool(Icons.contrast, 'Enhance', () => _apply(const PageOp(PageOpKind.enhance))),
        tool(Icons.restore, 'Reset page', () async {
          page.current = page.original;
          await _renderPreview(page);
        }),
        tool(Icons.delete_outline, 'Remove page', _pages.length <= 1
            ? null
            : () => setState(() {
                  _pages.removeAt(_sel);
                  _sel = _sel.clamp(0, _pages.length - 1);
                })),
      ]),
    );
  }

  Widget _strip() {
    return SizedBox(
      height: 96,
      child: ReorderableListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: _pages.length,
        onReorder: (a, b) => setState(() {
          if (b > a) b--;
          final p = _pages.removeAt(a);
          _pages.insert(b, p);
          _sel = b;
        }),
        itemBuilder: (c, i) {
          final p = _pages[i];
          return Padding(
            key: ObjectKey(p),
            padding: const EdgeInsets.only(right: 8),
            child: Semantics(
              label: 'Page ${i + 1}${i == _sel ? ', selected' : ''}. Long press and drag to reorder.',
              child: GestureDetector(
                onTap: () => setState(() {
                  _sel = i;
                  _tool = _Tool.none;
                }),
                child: Container(
                  width: 60,
                  decoration: BoxDecoration(
                    border: Border.all(color: i == _sel ? Theme.of(c).colorScheme.primary : Colors.transparent, width: 3),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Stack(fit: StackFit.expand, children: [
                    if (p.preview != null) ClipRRect(borderRadius: BorderRadius.circular(5), child: Image.memory(p.preview!, fit: BoxFit.cover)),
                    Align(
                      alignment: Alignment.bottomRight,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5),
                        color: Colors.black54,
                        child: Text('${i + 1}', style: const TextStyle(color: Colors.white)),
                      ),
                    ),
                  ]),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _PageCanvas extends StatelessWidget {
  final Uint8List image;
  final double aspect;
  final _Tool tool;
  final List<Offset> corners;
  final ValueChanged<List<Offset>> onCorners;
  const _PageCanvas({required this.image, required this.aspect, required this.tool, required this.corners, required this.onCorners});

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: aspect,
      child: LayoutBuilder(builder: (context, c) {
        final size = Size(c.maxWidth, c.maxHeight);
        return Stack(clipBehavior: Clip.none, children: [
          Positioned.fill(child: Image.memory(image, fit: BoxFit.fill, gaplessPlayback: true, semanticLabel: 'Page preview')),
          if (tool != _Tool.none) ...[
            Positioned.fill(child: CustomPaint(painter: _QuadPainter(corners, Theme.of(context).colorScheme.primary))),
            for (var i = 0; i < 4; i++)
              Positioned(
                left: corners[i].dx * size.width - 24,
                top: corners[i].dy * size.height - 24,
                child: Semantics(
                  label: 'Corner handle ${['top left', 'top right', 'bottom right', 'bottom left'][i]}',
                  child: GestureDetector(
                    onPanUpdate: (d) {
                      final next = [...corners];
                      final p = Offset(
                        (corners[i].dx + d.delta.dx / size.width).clamp(0.0, 1.0),
                        (corners[i].dy + d.delta.dy / size.height).clamp(0.0, 1.0),
                      );
                      next[i] = p;
                      if (tool == _Tool.crop) {
                        // Keep a rectangle: neighbours share x or y.
                        final hNeighbour = [1, 0, 3, 2][i];
                        final vNeighbour = [3, 2, 1, 0][i];
                        next[hNeighbour] = Offset(next[hNeighbour].dx, p.dy);
                        next[vNeighbour] = Offset(p.dx, next[vNeighbour].dy);
                      }
                      onCorners(next);
                    },
                    child: Container(
                      width: 48,
                      height: 48,
                      alignment: Alignment.center,
                      child: Container(
                        width: 22,
                        height: 22,
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primary,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ]);
      }),
    );
  }
}

class _QuadPainter extends CustomPainter {
  final List<Offset> c;
  final Color color;
  _QuadPainter(this.c, this.color);
  @override
  void paint(Canvas canvas, Size s) {
    final path = Path()..moveTo(c[0].dx * s.width, c[0].dy * s.height);
    for (final o in c.skip(1)) {
      path.lineTo(o.dx * s.width, o.dy * s.height);
    }
    path.close();
    final outside = Path.combine(PathOperation.difference, Path()..addRect(Offset.zero & s), path);
    canvas.drawPath(outside, Paint()..color = Colors.black.withValues(alpha: 0.45));
    canvas.drawPath(path, Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2);
  }

  @override
  bool shouldRepaint(_QuadPainter o) => true;
}
