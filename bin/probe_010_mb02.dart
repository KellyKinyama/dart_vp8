import 'dart:io';
import 'dart:typed_data';

import 'package:dart_vp8/dart_vp8.dart';

void main() {
  final ivf =
      File('test/fixtures/vp80-00-comprehensive-010.ivf').readAsBytesSync();
  final reader = IvfReader(Uint8List.fromList(ivf));
  final dec = Vp8Decoder();
  int frame = 0;
  // mbCols of 320x240 = 20. Frame 24 MB(0,2) is 0*20+2 = 2 within that frame.
  // global MB idx grows across all frames, so we filter by frame counter.
  dec.debugPerMbHook = (gIdx, qcoeff, eobs, mb, dq) {
    if (frame == 24 && gIdx >= 24 * 20 * 15 && gIdx <= 24 * 20 * 15 + 4) {
      print(
          'gIdx=$gIdx mb yMode=${mb.yMode} uvMode=${mb.uvMode} ref=${mb.refFrame} mv=(${mb.mv.row},${mb.mv.col}) seg=${mb.segmentId} skip=${mb.skipCoeff} is4x4=${mb.is4x4}');
      print(
          '  dq y1=(${dq.y1Dc},${dq.y1Ac}) y2=(${dq.y2Dc},${dq.y2Ac}) uv=(${dq.uvDc},${dq.uvAc})');
      for (int b = 0; b < 25; b++) {
        if (eobs[b] == 0) continue;
        final base = b * 16;
        final List<int> nz = [];
        for (int i = 0; i < 16; i++) {
          if (qcoeff[base + i] != 0) nz.add(qcoeff[base + i]);
        }
        print('   blk$b eob=${eobs[b]} nz=$nz');
      }
    }
  };
  while (true) {
    final f = reader.nextFrame();
    if (f == null) break;
    dec.decode(f);
    frame++;
  }
}
