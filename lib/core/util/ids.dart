import 'dart:math';

final _rng = Random();
int _counter = 0;

/// Short unique id, good enough for local objects (notes, pedals, pieces).
String newId([String prefix = '']) {
  _counter = (_counter + 1) & 0xFFFFFF;
  final t = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  final r = _rng.nextInt(1 << 30).toRadixString(36);
  return '$prefix$t${_counter.toRadixString(36)}$r';
}
