import 'dart:io';
import 'dart:typed_data';

import 'package:dart_vp8/dart_vp8.dart';

void main() {
  final ivf = File(
          'c:/www/dart/libvpx/dart_vp8/test/fixtures/vp80-00-comprehensive-001.ivf')
      .readAsBytesSync();
  final reader = IvfReader(Uint8List.fromList(ivf));
  final dec = Vp8Decoder();

  // Decode frames 0, 1. After this, refLast holds frame 1.
  dec.decode(reader.nextFrame()!);
  dec.decode(reader.nextFrame()!);
  final ref = dec.debugRefLast!;
  print('refLast yStride=${ref.yStride} yOrigin=${ref.yOrigin}');

  // Dump row 20 of refLast cols 165..185 (inclusive), then run sixtap manually.
  final rowOff = ref.yOrigin + 20 * ref.yStride;
  stdout.write('refLast row20 cols 165..185:');
  for (int x = 165; x <= 185; x++) {
    stdout.write(' ${ref.y[rowOff + x]}');
  }
  stdout.writeln();
  // Also row 21..23.
  for (int r = 21; r <= 23; r++) {
    final off = ref.yOrigin + r * ref.yStride;
    stdout.write('refLast row$r cols 165..185:');
    for (int x = 165; x <= 185; x++) {
      stdout.write(' ${ref.y[off + x]}');
    }
    stdout.writeln();
  }

  // Run our sixtap 16x16 with MV=(0,226). Intcol=28, subCol=2.
  // Source top-left at MB(1,9): mbRow=1, mbCol=9 → y=16+0=16, x=144+28=172.
  final dst = Uint8List(16 * 16);
  final srcOff = ref.yOrigin + 16 * ref.yStride + 172;
  sixtapPredict16x16(ref.y, srcOff, ref.yStride, 2, 0, dst, 0, 16);
  stdout.writeln('Predicted MB Y row 4 (output rows 4 cols 0..15):');
  for (int r = 4; r < 5; r++) {
    stdout.write('  row $r:');
    for (int c = 0; c < 16; c++) {
      stdout.write(' ${dst[r * 16 + c]}');
    }
    stdout.writeln();
  }
}
