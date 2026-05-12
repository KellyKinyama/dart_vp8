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
    dec.decode(reader.nextFrame()!);
    if (i == 2) {
      final mi = dec.debugLastModeInfo;
      final mbIdx = 7 * dec.debugMbCols + 9;
      final mb = mi[mbIdx];
      print('Frame 2 MB(7,9): mode=${mb.yMode} ref=${mb.refFrame} '
          'skipCoeff=${mb.skipCoeff} is4x4=${mb.is4x4} '
          'seg=${mb.segmentId} eobMax=${mb.eobMax} '
          'mv=(${mb.mv.row},${mb.mv.col})');
      print('  filter_level=${dec.debugFilterLevel(mbIdx)}');
      // Also neighbor MB(7,8) since col 152 is on the V-edge between MB(7,8)/MB(7,9)? Actually no — col 152 is INSIDE MB(7,9) at col 8.
      final mbL = mi[7 * dec.debugMbCols + 8];
      print('Frame 2 MB(7,8): mode=${mbL.yMode} skipCoeff=${mbL.skipCoeff} '
          'is4x4=${mbL.is4x4} fl=${dec.debugFilterLevel(7 * dec.debugMbCols + 8)}');
    }
  }
}
