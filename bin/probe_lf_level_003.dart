// Print Dart's per-MB filter level for vp80-00-comprehensive-003 frame 1.
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_vp8/dart_vp8.dart';

void main() {
  final ivf =
      File('test/fixtures/vp80-00-comprehensive-003.ivf').readAsBytesSync();
  final reader = IvfReader(Uint8List.fromList(ivf));
  final dec = Vp8Decoder();
  for (int i = 0; i <= 1; i++) {
    final f = reader.nextFrame();
    if (f == null) break;
    dec.decode(f);
  }
  // 11 cols x 9 rows.
  for (int r = 0; r < 9; r++) {
    final row = <int>[];
    for (int c = 0; c < 11; c++) {
      row.add(dec.debugFilterLevel(r * 11 + c));
    }
    print('row $r: $row');
  }
}
