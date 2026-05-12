import 'dart:io';
import 'dart:typed_data';

import 'package:dart_vp8/dart_vp8.dart';

void main() {
  final ivfBytes = File(
          'c:/www/dart/libvpx/dart_vp8/test/fixtures/vp80-00-comprehensive-001.ivf')
      .readAsBytesSync();
  final reader = IvfReader(Uint8List.fromList(ivfBytes));
  final dec = Vp8Decoder();
  for (int i = 0; i < 3; i++) {
    final df = dec.decode(reader.nextFrame()!);
    if (i == 2) {
      print('Dart WITH-LF frame 2, MB(7,9) cols 144..159:');
      for (int r = 112; r < 128; r++) {
        final row = <int>[];
        for (int c = 144; c < 160; c++) {
          row.add(df.y[r * df.yStride + c]);
        }
        print('  row${r.toString().padLeft(3)}: $row');
      }
    }
  }
}
