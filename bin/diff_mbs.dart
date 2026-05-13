// Diff dart vs ref YUV for any vector, listing all differing MBs in frame N.
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_vp8/dart_vp8.dart';

void main(List<String> args) {
  final name = args.isNotEmpty ? args[0] : 'vp80-00-comprehensive-003';
  final targetFrame = args.length > 1 ? int.parse(args[1]) : 1;
  final ivf = File('test/fixtures/$name.ivf').readAsBytesSync();
  final ref =
      File('C:/Temp/${name.substring(name.length - 3)}.yuv').readAsBytesSync();
  final reader = IvfReader(Uint8List.fromList(ivf));
  final dec = Vp8Decoder();
  int frameIdx = 0;
  while (true) {
    final f = reader.nextFrame();
    if (f == null) break;
    final d = dec.decode(f);
    if (frameIdx != targetFrame) {
      frameIdx++;
      continue;
    }
    final w = d.width, h = d.height;
    final cw = w >> 1, ch = h >> 1;
    final frameBytes = w * h * 3 ~/ 2;
    final off = frameIdx * frameBytes;
    final mbR = h ~/ 16;
    final mbC = w ~/ 16;
    print('Y plane MB diffs (frame $frameIdx, $w x $h, $mbR x $mbC):');
    for (int r = 0; r < mbR; r++) {
      for (int c = 0; c < mbC; c++) {
        bool diff = false;
        for (int yy = 0; yy < 16 && !diff; yy++) {
          for (int xx = 0; xx < 16; xx++) {
            final dy = d.y[(r * 16 + yy) * d.yStride + c * 16 + xx];
            final ry = ref[off + (r * 16 + yy) * w + c * 16 + xx];
            if (dy != ry) {
              diff = true;
              break;
            }
          }
        }
        if (diff) stdout.write('($r,$c) ');
      }
    }
    stdout.writeln();
    break;
  }
}
