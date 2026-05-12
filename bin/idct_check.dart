import 'dart:typed_data';

import 'package:dart_vp8/dart_vp8.dart';

void main() {
  // Y4 input post-Y1-AC dequant for frame 2 MB(1,9): DC=1, AC[4]=-10.
  final input = Int16List(16);
  input[0] = 1;
  input[4] = -10;
  final pred = Uint8List(4 * 4);
  for (int i = 0; i < 16; i++) {
    pred[i] = 17;
  }
  final dst = Uint8List(4 * 4);
  idct4x4Add(input, 0, pred, 0, 4, dst, 0, 4);
  print('Dart IDCT-add output (pred=17, DC=1, AC[4]=-10):');
  for (int r = 0; r < 4; r++) {
    print('  row $r: ${dst.sublist(r * 4, r * 4 + 4)}');
  }
}
