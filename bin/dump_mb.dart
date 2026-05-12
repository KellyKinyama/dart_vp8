import 'dart:io';
import 'dart:typed_data';

import 'package:dart_vp8/dart_vp8.dart';

void main() {
  final ivfBytes = File(
          'c:/www/dart/libvpx/dart_vp8/test/fixtures/vp80-00-comprehensive-001.ivf')
      .readAsBytesSync();
  final ref = File(
          'c:/www/dart/libvpx/dart_vp8/test/fixtures/vp80-00-comprehensive-001.yuv')
      .readAsBytesSync();
  final reader = IvfReader(Uint8List.fromList(ivfBytes));
  final dec = Vp8Decoder();
  for (int i = 0; i < 3; i++) {
    final f = reader.nextFrame()!;
    final df = dec.decode(f);
    if (i == 2) {
      print('frame 2 Y rows 112..127 cols 144..159 (MB 7,9):');
      final fOff = 2 * 38016;
      for (int r = 112; r <= 127; r++) {
        final got = df.y.sublist(r * df.yStride + 144, r * df.yStride + 160);
        final wnt = ref.sublist(fOff + r * 176 + 144, fOff + r * 176 + 160);
        final mk =
            List.generate(16, (k) => got[k] == wnt[k] ? '.' : '*').join();
        print('  r$r got=$got');
        print('       wnt=$wnt  $mk');
      }
    }
  }
}
