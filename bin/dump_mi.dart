import 'dart:io';
import 'dart:typed_data';

import 'package:dart_vp8/dart_vp8.dart';
import 'package:dart_vp8/src/mv.dart';

String refName(int r) {
  switch (r) {
    case 0:
      return 'INTRA';
    case 1:
      return 'LAST';
    case 2:
      return 'GOLDEN';
    case 3:
      return 'ALTREF';
  }
  return '?';
}

String modeName(int m) {
  if (m == 0) return 'DC';
  if (m == 1) return 'V';
  if (m == 2) return 'H';
  if (m == 3) return 'TM';
  if (m == 4) return 'B';
  if (m == 5) return 'NEAREST';
  if (m == 6) return 'NEAR';
  if (m == 7) return 'ZERO';
  if (m == 8) return 'NEW';
  if (m == 9) return 'SPLIT';
  return '?';
}

void main() {
  final ivfBytes = File(
          'c:/www/dart/libvpx/dart_vp8/test/fixtures/vp80-00-comprehensive-001.ivf')
      .readAsBytesSync();
  final reader = IvfReader(Uint8List.fromList(ivfBytes));
  final dec = Vp8Decoder();
  for (int i = 0; i < 3; i++) {
    final f = reader.nextFrame()!;
    dec.decode(f);
    if (i == 2) {
      final mi = dec.debugLastModeInfo;
      // Print MB info for MB rows 6, 7, 8 and MB cols 8, 9, 10 (around the diff area).
      for (int r = 0; r <= 2; r++) {
        for (int c = 7; c <= 10; c++) {
          final m = mi[r * dec.debugMbCols + c];
          final fl = dec.debugFilterLevel(r * dec.debugMbCols + c);
          print(
              'MB($r,$c) ref=${refName(m.refFrame)} mode=${modeName(m.yMode)} uv=${modeName(m.uvMode)} mv=(${m.mv.row},${m.mv.col}) skip=${m.skipCoeff} eobMax=${m.eobMax} fl=$fl');
          if (m.yMode == splitMv) {
            for (int b = 0; b < 16; b++) {
              final p = m.bMvs[b];
              final row = ((p >> 16) & 0xffff);
              final col = (p & 0xffff);
              final rr = row >= 0x8000 ? row - 0x10000 : row;
              final cc = col >= 0x8000 ? col - 0x10000 : col;
              print('   b$b mv=($rr,$cc)');
            }
          }
        }
      }
    }
  }
}
