import 'dart:io';
import 'dart:typed_data';

import 'package:dart_vp8/dart_vp8.dart';

void main() {
  final ivfBytes = File(
          'c:/www/dart/libvpx/dart_vp8/test/fixtures/vp80-00-comprehensive-001.ivf')
      .readAsBytesSync();
  final ref = File(
          'c:/www/dart/libvpx/dart_vp8/test/fixtures/vp80-00-comprehensive-001.nolf.yuv')
      .readAsBytesSync();
  final reader = IvfReader(Uint8List.fromList(ivfBytes));
  final dec = Vp8Decoder();
  dec.debugSkipLoopFilter = true;
  for (int i = 0; i <= 22; i++) {
    final df = dec.decode(reader.nextFrame()!);
    if (i == 22) {
      final fOff = 22 * 38016;
      // Show MB(6,8) rows 96..111 cols 128..143 (16x16 MB).
      print('Frame 22 MB(6,8) NO-LF Y dart vs libvpx:');
      for (int r = 96; r < 112; r++) {
        final dartRow = <int>[];
        final refRow = <int>[];
        for (int c = 128; c < 144; c++) {
          dartRow.add(df.y[r * df.yStride + c]);
          refRow.add(ref[fOff + r * 176 + c]);
        }
        final diffs = <int>[];
        for (int k = 0; k < 16; k++) {
          if (dartRow[k] != refRow[k]) diffs.add(k);
        }
        print('  r$r dart=$dartRow');
        if (diffs.isNotEmpty) print('       ref =$refRow  diffs@$diffs');
      }
      final mi = dec.debugLastModeInfo;
      final mb = mi[6 * dec.debugMbCols + 8];
      print('MB(6,8) info: mode=${mb.yMode} ref=${mb.refFrame} '
          'skipCoeff=${mb.skipCoeff} is4x4=${mb.is4x4} seg=${mb.segmentId} '
          'mv=(${mb.mv.row},${mb.mv.col}) eobMax=${mb.eobMax}');
    }
  }
}
